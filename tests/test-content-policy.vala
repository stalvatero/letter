const string REMOTE_ALLOWED = "img-src letterimg: data: blob: *; style-src 'unsafe-inline' *;";
const string OWN_SIGNATURE = "<p>Me</p><img src=\"https://cdn.example.com/logo.png\">";

Settings settings_trusting (string sender) {
    var settings = new Settings (Config.APP_ID);
    settings.set_strv ("trusted-senders", { sender });
    return settings;
}

Mail.Account my_account () {
    return new Mail.Account () { uid = "me", email = "me@example.com", kind = Mail.AccountKind.GOOGLE };
}

Mail.MessageContent quote_from (string from_email) {
    return new Mail.MessageContent () {
        from = "Sender <%s>".printf (from_email),
        from_email = from_email,
        html = "<p>quoted</p>",
    };
}

string compose_policy (Mail.MessageContent? quoted, Mail.Identity? identity = null) {
    return Mail.Utils.compose_content_policy_meta (
        settings_trusting ("friend@example.com"),
        quoted,
        my_account (),
        identity,
        OWN_SIGNATURE
    );
}

void test_untrusted_policy_blocks_every_remote_load () {
    var policy = Mail.Utils.content_policy_meta (false);
    assert (policy.has_prefix ("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "));
    assert (policy.contains ("img-src letterimg: data: blob:;"));
    assert (policy.contains ("style-src 'unsafe-inline';"));
    assert (policy.contains ("font-src data:;"));
    assert (policy.contains ("media-src data: blob:;"));
    assert (!policy.contains ("*"));
}

void test_trusted_policy_allows_remote_content () {
    var policy = Mail.Utils.content_policy_meta (true);
    assert (policy.contains (REMOTE_ALLOWED));
    assert (policy.contains ("font-src data: *;"));
    assert (policy.contains ("media-src data: blob: *;"));
}

void test_every_policy_blocks_active_content () {
    foreach (var policy in new string[] {
        Mail.Utils.content_policy_meta (false),
        Mail.Utils.content_policy_meta (false, { "https://cdn.example.com/logo.png" }),
        Mail.Utils.content_policy_meta (true),
    }) {
        assert (policy.contains ("default-src 'none'"));
        assert (policy.contains ("connect-src data: blob:;"));
        assert (policy.contains ("form-action 'none'"));
        assert (policy.contains ("base-uri 'none'"));
        assert (!policy.contains ("script-src"));
        assert (!policy.contains ("frame-src"));
    }
}

void test_image_sources_without_images () {
    assert (Mail.Utils.html_remote_image_sources ("").length == 0);
    assert (Mail.Utils.html_remote_image_sources ("<p>no images</p>").length == 0);
    assert (Mail.Utils.html_remote_image_sources ("<img src=\"data:image/png;base64,AAAA\">").length == 0);
    assert (Mail.Utils.html_remote_image_sources ("<a href=\"https://link.example/\">l</a>").length == 0);
}

void test_image_sources_drop_query_and_fragment () {
    var sources = Mail.Utils.html_remote_image_sources (
        "<IMG alt=x SRC=\"https://cdn.example.com/logo.png?v=2#top\">"
        + "<img src='http://a.example/b.gif'><img src=https://c.example/d.png>"
    );
    assert (string.joinv (" ", sources)
        == "https://cdn.example.com/logo.png http://a.example/b.gif https://c.example/d.png");
}

void test_image_sources_cannot_inject_directives () {
    var sources = Mail.Utils.html_remote_image_sources (
        "<img src=\"https://e.example/x;img-src *\"><img src=\"https://f.example/p,q.png\">"
    );
    assert (string.joinv (" ", sources) == "https://e.example/x https://f.example/p");
}

void test_new_message_allows_remote () {
    assert (compose_policy (null).contains (REMOTE_ALLOWED));
}

void test_reply_to_stranger_allows_only_own_signature_images () {
    var policy = compose_policy (quote_from ("x@evil.example"));
    assert (policy.contains ("img-src letterimg: data: blob: https://cdn.example.com/logo.png;"));
    assert (policy.contains ("style-src 'unsafe-inline';"));
}

void test_reply_to_trusted_sender_allows_remote () {
    assert (compose_policy (quote_from ("friend@example.com")).contains (REMOTE_ALLOWED));
}

void test_sender_falls_back_to_from_header () {
    var quoted = new Mail.MessageContent () { from = "Friend <friend@example.com>", html = "" };
    assert (compose_policy (quoted).contains (REMOTE_ALLOWED));
}

void test_own_message_allows_remote () {
    assert (compose_policy (quote_from ("me@example.com")).contains (REMOTE_ALLOWED));
}

void test_own_alias_allows_remote () {
    var identity = new Mail.Identity () { address = "alias@example.org", aliases = { "other@example.org" } };
    assert (compose_policy (quote_from ("other@example.org"), identity).contains (REMOTE_ALLOWED));
}

void test_policy_goes_after_doctype () {
    assert (Mail.Utils.insert_after_doctype ("<!DOCTYPE html><html><body>x", "<meta>")
        == "<!DOCTYPE html><meta><html><body>x");
    assert (Mail.Utils.insert_after_doctype ("\n <!doctype html>\n<p>x", "<meta>")
        == "\n <!doctype html><meta>\n<p>x");
}

void test_policy_goes_first_without_doctype () {
    assert (Mail.Utils.insert_after_doctype ("<html><body>x", "<meta>") == "<meta><html><body>x");
    assert (Mail.Utils.insert_after_doctype ("", "<meta>") == "<meta>");
}

void main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/content-policy/untrusted-blocks-every-remote-load", test_untrusted_policy_blocks_every_remote_load);
    Test.add_func ("/content-policy/trusted-allows-remote-content", test_trusted_policy_allows_remote_content);
    Test.add_func ("/content-policy/every-policy-blocks-active-content", test_every_policy_blocks_active_content);
    Test.add_func ("/content-policy/goes-after-doctype", test_policy_goes_after_doctype);
    Test.add_func ("/content-policy/goes-first-without-doctype", test_policy_goes_first_without_doctype);
    Test.add_func ("/image-sources/without-images", test_image_sources_without_images);
    Test.add_func ("/image-sources/drop-query-and-fragment", test_image_sources_drop_query_and_fragment);
    Test.add_func ("/image-sources/cannot-inject-directives", test_image_sources_cannot_inject_directives);
    Test.add_func ("/compose-policy/new-message-allows-remote", test_new_message_allows_remote);
    Test.add_func ("/compose-policy/reply-to-stranger-allows-only-own-signature-images", test_reply_to_stranger_allows_only_own_signature_images);
    Test.add_func ("/compose-policy/reply-to-trusted-sender-allows-remote", test_reply_to_trusted_sender_allows_remote);
    Test.add_func ("/compose-policy/sender-falls-back-to-from-header", test_sender_falls_back_to_from_header);
    Test.add_func ("/compose-policy/own-message-allows-remote", test_own_message_allows_remote);
    Test.add_func ("/compose-policy/own-alias-allows-remote", test_own_alias_allows_remote);
    Test.run ();
}
