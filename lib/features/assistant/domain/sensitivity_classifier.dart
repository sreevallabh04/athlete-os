/// Deterministic, on-device sensitivity screen. Runs BEFORE any AI call and
/// independently of it. Any flag makes a message high risk, which the
/// [ReplyPolicyEngine] treats as "never auto-send".
enum SensitivityFlag {
  otp('otp', 'Verification code'),
  credentials('credentials', 'Password / credentials'),
  money('money', 'Money / payments'),
  legal('legal', 'Legal'),
  medical('medical', 'Medical'),
  crisis('crisis', 'Emergency / crisis'),
  commitment('commitment', 'Commitment'),
  unknownSender('unknown_sender', 'Unknown sender'),
  ambiguous('ambiguous', 'Unclear context'),
  groupChat('group', 'Group chat'),
  lowIdentity('low_identity', 'Contact not reliably identified');

  const SensitivityFlag(this.key, this.label);
  final String key;
  final String label;

  static SensitivityFlag? fromKey(String key) {
    for (final f in values) {
      if (f.key == key) return f;
    }
    return null;
  }

  /// Content-type flags (as opposed to context flags like group/identity).
  bool get isContent => index <= SensitivityFlag.commitment.index;
}

class SensitivityResult {
  const SensitivityResult(this.flags);
  final Set<SensitivityFlag> flags;

  bool get isSensitive => flags.isNotEmpty;

  /// low | high. Any flag → high (never auto-send).
  String get risk => flags.isEmpty ? 'low' : 'high';

  String? get csv => flags.isEmpty
      ? null
      : (flags.map((f) => f.key).toList()..sort()).join(',');

  static Set<SensitivityFlag> parseCsv(String? csv) => {
    for (final k in (csv ?? '').split(',')) ?SensitivityFlag.fromKey(k.trim()),
  };
}

class SensitivityClassifier {
  const SensitivityClassifier();

  static RegExp _words(List<String> words) => RegExp(
    r'(^|[^\p{L}\p{N}])(' + words.join('|') + r')($|[^\p{L}\p{N}])',
    caseSensitive: false,
    unicode: true,
  );

  static final _otp = _words([
    'otp',
    r'one[\s-]?time[\s-]?(pass(word|code)?|code|pin)',
    r'verification\s+code',
    r'verify(ing)?\s+code',
    r'security\s+code',
    r'auth(entication)?\s+code',
    r'login\s+code',
    r'sign[\s-]?in\s+code',
    '2fa',
    'passcode',
    r'confirmation\s+code',
  ]);
  static final _digits = RegExp(r'(^|\D)\d{4,8}(\D|$)');
  static final _codeWord = RegExp(
    r'\b(code|pin|verify|verification|otp)\b',
    caseSensitive: false,
  );
  static final _credentials = _words([
    r'pass\s?words?',
    'passwd',
    'pwd',
    'pin',
    'cvv',
    'cvc',
    'username',
    'credentials?',
    r'log\s?in\s+details',
    r'api[\s_-]?key',
    'secret',
    r'account\s+(number|no\.?)',
    'ssn',
    'aadhaa?r',
    r'pan\s+card',
    r'card\s+(number|details)',
    r'reset\s+your\s+password',
  ]);
  static final _currency = RegExp(
    r'[₹$€£¥]|\brs\.?\s?\d',
    caseSensitive: false,
  );
  static final _money = _words([
    'upi',
    'banks?',
    'banking',
    'transfer(red|ring)?',
    'invoices?',
    'loans?',
    'pay',
    'paid',
    'payments?',
    'paying',
    'refunds?',
    'emi',
    'gpay',
    'paytm',
    'phonepe',
    'neft',
    'imps',
    'rtgs',
    'ifsc',
    'wallet',
    r'credit\s+card',
    'debit',
    'owe',
    'money',
    'cash',
    'salary',
    'deposit',
    'inr',
    'usd',
    'rupees?',
    'dollars?',
    'lakhs?',
    'crores?',
    'bitcoin',
    'crypto',
  ]);
  static final _legal = _words([
    'contracts?',
    'agreements?',
    'court',
    'lawyers?',
    'attorney',
    'advocate',
    'legal(ly)?',
    'lawsuit',
    r'legal\s+notice',
    'sign',
    'signed',
    'signature',
    'nda',
    'affidavit',
    'notary',
    'police',
    'fir',
  ]);
  static final _medical = _words([
    'doctor',
    r'dr\.?',
    'diagnos(is|ed)',
    'prescriptions?',
    'symptoms?',
    'hospital',
    'clinic',
    'medicines?',
    'medications?',
    'dose',
    'dosage',
    'surgery',
    r'test\s+results?',
    'fever',
    'injur(y|ed)',
    'pregnan(t|cy)',
    'therapy',
    'therapist',
    'blood',
    'covid',
    'allerg(y|ic)',
    'icu',
  ]);
  static final _crisis = _words([
    'emergency',
    r'help\s+me',
    r'urgent(ly)?\s+help',
    'suicid(e|al)',
    r'kill\s+(my|him|her|them)sel(f|ves)',
    r'kill\s+you',
    r'self[\s-]?harm',
    r'hurt\s+myself',
    r'want\s+to\s+die',
    r'end\s+it\s+all',
    'threat(en(ed|ing)?)?',
    'accident',
    'ambulance',
    'danger',
    'abuse(d)?',
    'attack(ed)?',
    '911',
    '112',
  ]);
  static final _commitment = _words([
    'promise',
    'commit(ment)?',
    'guarantee',
    'deadline',
    'confirm(ed|ing)?',
    r'sign\s+up',
    'rsvp',
    'deal',
    'offer',
    'borrow',
    'lend',
    r'book(ed|ing)?',
    'reserve',
    'interview',
    'decision',
    'decide',
    r'can\s+you\s+(come|do|make|attend|send|pay)',
    r'will\s+you',
    r'are\s+you\s+coming',
  ]);
  static final _phoneLike = RegExp(r'^\+?[\d\s\-()]{6,}$');
  static final _letters = RegExp(r'[\p{L}\p{N}]', unicode: true);

  /// Classifies [text]. Context flags: [isGroup], [identityConfidence]
  /// ('high'|'low'), [sender] (null/phone number = unknown) and
  /// [contactKnown] (a contact rule exists and is approved).
  SensitivityResult classify({
    required String text,
    String? sender,
    bool isGroup = false,
    String identityConfidence = 'low',
    bool contactKnown = false,
  }) {
    final t = text.trim();
    final flags = <SensitivityFlag>{};
    if (_otp.hasMatch(t) || (_digits.hasMatch(t) && _codeWord.hasMatch(t))) {
      flags.add(SensitivityFlag.otp);
    }
    if (_credentials.hasMatch(t)) flags.add(SensitivityFlag.credentials);
    if (_currency.hasMatch(t) || _money.hasMatch(t)) {
      flags.add(SensitivityFlag.money);
    }
    if (_legal.hasMatch(t)) flags.add(SensitivityFlag.legal);
    if (_medical.hasMatch(t)) flags.add(SensitivityFlag.medical);
    if (_crisis.hasMatch(t)) flags.add(SensitivityFlag.crisis);
    if (_commitment.hasMatch(t)) flags.add(SensitivityFlag.commitment);

    final s = sender?.trim() ?? '';
    if (!contactKnown && (s.isEmpty || _phoneLike.hasMatch(s))) {
      flags.add(SensitivityFlag.unknownSender);
    }
    final words = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    if (!_letters.hasMatch(t) || (words <= 1 && t.length < 6)) {
      flags.add(SensitivityFlag.ambiguous);
    }
    if (isGroup) flags.add(SensitivityFlag.groupChat);
    if (identityConfidence != 'high') flags.add(SensitivityFlag.lowIdentity);
    return SensitivityResult(flags);
  }
}
