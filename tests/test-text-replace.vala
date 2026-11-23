const string[] PIECES = {
    "a", "\\", "\"", "'", "&", "quot;", "#39;", "apos;", "​", " ", "\t", "\n", ".", "$",
};

const string[] PAIRS = {
    "\\\"", "\"",
    "\\'", "'",
    "&quot;", "\"",
    "&#39;", "'",
    "&apos;", "'",
    "​", "",
    " ", " ",
    "\\", "\\\\",
    "\t", "\\t",
    "\n", "\\n",
    "a", "aa",
    "aa", "a",
    ".", "\\0",
    "$", "$1",
    "a", "a",
};

void collect_texts (GenericArray<string> texts, string prefix, int depth) {
    texts.add (prefix);
    if (depth == 0)
        return;
    foreach (var piece in PIECES)
        collect_texts (texts, prefix + piece, depth - 1);
}

void test_replace_literal_matches_string_replace () {
    var texts = new GenericArray<string> ();
    collect_texts (texts, "", 4);
    for (int i = 0; i < PAIRS.length; i += 2) {
        foreach (var text in texts.data)
            assert_cmpstr (Mail.Utils.replace_literal (text, PAIRS[i], PAIRS[i + 1]), EQ, text.replace (PAIRS[i], PAIRS[i + 1]));
    }
}

void test_replace_literal_matches_string_replace_on_empty_pattern () {
    assert_cmpstr (Mail.Utils.replace_literal ("abc", "", "x"), EQ, "abc".replace ("", "x"));
}

void test_sanitize_recipient_text () {
    assert_cmpstr (Mail.Utils.sanitize_recipient_text (null), EQ, "");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text (" ​ "), EQ, "");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text ("\\\"Jane Doe\\\""), EQ, "Jane Doe");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text ("O\\'Brien"), EQ, "O'Brien");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text ("&quot;Jane Doe&quot;"), EQ, "Jane Doe");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text ("Ann&#39;s &apos;Team&apos; x"), EQ, "Ann's 'Team' x");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text ("Ja​ne Doe"), EQ, "Jane Doe");
    assert_cmpstr (Mail.Utils.sanitize_recipient_text ("jane@example.com;"), EQ, "jane@example.com");
}

void test_sanitize_message_preview () {
    assert (Mail.Utils.sanitize_message_preview (null) == null);
    assert (Mail.Utils.sanitize_message_preview ("") == null);
    assert (Mail.Utils.sanitize_message_preview ("[image: Google]") == null);
    assert (Mail.Utils.sanitize_message_preview ("[Firma Concorso.png]") == null);
    assert (Mail.Utils.sanitize_message_preview ("-- Salvatore Oscurato [Firma Concorso.png]") == null);
    assert_cmpstr (
        Mail.Utils.sanitize_message_preview ("[image: Google] Hai consentito all'app GNOME"),
        EQ,
        "Hai consentito all'app GNOME"
    );
    assert_cmpstr (
        Mail.Utils.sanitize_message_preview ("Ciao\nmondo"),
        EQ,
        "Ciao mondo"
    );

    /* Invalid UTF-8 must not abort (Vala string.replace → GRegex assert). */
    var bad = new StringBuilder ();
    bad.append ("Ciao");
    bad.append_c ((char) 0xff);
    bad.append ("\nmondo");
    var cleaned = Mail.Utils.sanitize_message_preview (bad.str);
    assert (cleaned != null && cleaned.contains ("Ciao") && cleaned.contains ("mondo"));
    /* Must not amplify (unichar)-1 into six FF BF bytes (#49). */
    assert (!cleaned.contains ("\xff\xbf"));
    assert (cleaned.length <= Mail.Utils.MESSAGE_PREVIEW_MAX_BYTES);
}

void test_sanitize_message_preview_no_utf8_amplification () {
    var poisoned = new StringBuilder ("Bonjour");
    /* One invalid byte → old collapse_spaces wrote 6; next pass ×6 again. */
    poisoned.append_c ((char) 0xff);
    var once = Mail.Utils.sanitize_message_preview (poisoned.str);
    assert (once != null);
    assert (once.length < 64);
    assert (!once.contains ("\xff"));

    /* Simulate a cache field already grown like 6^8 invalid bytes after prose. */
    var huge = new StringBuilder ("Texte français.");
    for (int i = 0; i < 4096; i++)
        huge.append ("\xff\xbf\xbf\xbf\xbf\xbf");
    assert (huge.str.length > 20000);
    var capped = Mail.Utils.sanitize_message_preview (huge.str);
    assert (capped != null);
    assert (capped.has_prefix ("Texte"));
    assert (capped.length <= Mail.Utils.MESSAGE_PREVIEW_MAX_BYTES);
    assert (!capped.contains ("\xff"));
}

void test_compare_versions () {
    assert_cmpstr (Mail.Utils.normalize_version ("v1.7.0"), EQ, "1.7.0");
    assert_cmpstr (Mail.Utils.normalize_version ("1.7.0~rc.1"), EQ, "1.7.0");
    assert (Mail.Utils.compare_versions ("1.7.0", "1.6.0") > 0);
    assert (Mail.Utils.compare_versions ("v1.7.0", "1.7.0") == 0);
    assert (Mail.Utils.compare_versions ("1.6.9", "1.7.0") < 0);
    assert (Mail.Utils.compare_versions ("1.7", "1.7.0") == 0);
}

void test_header_cache_escape () {
    assert_cmpstr (Mail.Window.header_cache_escape (null), EQ, "");
    assert_cmpstr (Mail.Window.header_cache_escape (""), EQ, "");
    assert_cmpstr (Mail.Window.header_cache_escape ("plain"), EQ, "plain");
    assert_cmpstr (Mail.Window.header_cache_escape ("a\tb\nc\\d"), EQ, "a\\tb\\nc\\\\d");
    assert_cmpstr (Mail.Window.header_cache_escape ("\\t\\n"), EQ, "\\\\t\\\\n");
}

void test_header_cache_escape_round_trip () {
    var texts = new GenericArray<string> ();
    collect_texts (texts, "", 4);
    foreach (var text in texts.data) {
        var escaped = Mail.Window.header_cache_escape (text);
        assert (!escaped.contains ("\t") && !escaped.contains ("\n"));
        assert_cmpstr (Mail.Window.header_cache_unescape (escaped), EQ, text);
    }
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/replace-literal/matches-string-replace", test_replace_literal_matches_string_replace);
    Test.add_func ("/replace-literal/matches-string-replace-on-empty-pattern", test_replace_literal_matches_string_replace_on_empty_pattern);
    Test.add_func ("/sanitize-recipient-text/cleans-names", test_sanitize_recipient_text);
    Test.add_func ("/sanitize-message-preview/strips-image-placeholders", test_sanitize_message_preview);
    Test.add_func ("/sanitize-message-preview/no-utf8-amplification", test_sanitize_message_preview_no_utf8_amplification);
    Test.add_func ("/compare-versions/orders-semver", test_compare_versions);
    Test.add_func ("/header-cache/escape", test_header_cache_escape);
    Test.add_func ("/header-cache/escape-round-trip", test_header_cache_escape_round_trip);
    Test.run ();
}
