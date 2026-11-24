/**
 * Standalone IMAP spike — Platform Phase 2 exploration.
 *
 *   LETTER_IMAP_HOST=imap.gmail.com \
 *   LETTER_IMAP_USER=you@gmail.com \
 *   LETTER_IMAP_PASS='app-password' \
 *   ./letter-imap-spike
 *
 * Optional: LETTER_IMAP_MAILBOX=INBOX  LETTER_IMAP_PORT=993
 */
private static int main (string[] args) {
    var host = Environment.get_variable ("LETTER_IMAP_HOST");
    var user = Environment.get_variable ("LETTER_IMAP_USER");
    var pass = Environment.get_variable ("LETTER_IMAP_PASS");
    var mailbox = Environment.get_variable ("LETTER_IMAP_MAILBOX") ?? "INBOX";
    var port_s = Environment.get_variable ("LETTER_IMAP_PORT");
    uint16 port = 993;
    if (port_s != null && port_s.length > 0) {
        uint64 p = 0;
        if (uint64.try_parse (port_s, out p) && p > 0 && p <= 65535)
            port = (uint16) p;
    }

    if (host == null || user == null || pass == null
        || host.length == 0 || user.length == 0 || pass.length == 0) {
        stderr.printf (
            "Usage: set LETTER_IMAP_HOST, LETTER_IMAP_USER, LETTER_IMAP_PASS\n" +
            "Optional: LETTER_IMAP_MAILBOX (default INBOX), LETTER_IMAP_PORT (default 993)\n" +
            "Example Gmail: host=imap.gmail.com and a Google app password.\n"
        );
        return 2;
    }

    try {
        var client = new LetterImap.Client ();
        stdout.printf ("Connecting %s:%u (TLS)…\n", host, port);
        client.connect_tls (host, port);
        stdout.printf ("Greeting: %s\n", client.greeting ?? "");

        stdout.printf ("LOGIN as %s…\n", user);
        client.login (user, pass);
        stdout.printf ("LOGIN ok\n");

        var boxes = client.list_mailboxes ();
        stdout.printf ("LIST → %u mailbox(es)\n", boxes.length);
        var show = uint.min (boxes.length, 20);
        for (uint i = 0; i < show; i++)
            stdout.printf ("  %s\n", boxes[i]);
        if (boxes.length > show)
            stdout.printf ("  … (%u more)\n", boxes.length - show);

        var exists = client.select (mailbox);
        stdout.printf ("SELECT %s → %u message(s)\n", mailbox, exists);
        if (exists == 0) {
            stdout.printf ("Mailbox empty; done.\n");
            client.logout ();
            return 0;
        }

        var from = exists > 5 ? exists - 4 : 1;
        var headers = client.fetch_headers (from, exists);
        stdout.printf ("FETCH headers %u:%u → %u\n", from, exists, headers.length);
        for (uint i = 0; i < headers.length; i++) {
            var h = headers[i];
            stdout.printf (
                "  #%u  %s\n    From: %s\n    Date: %s\n",
                h.seq,
                h.subject ?? "(no subject)",
                h.from ?? "(unknown)",
                h.date ?? "(unknown)"
            );
        }

        var body_seq = exists;
        var body = client.fetch_body (body_seq);
        stdout.printf ("FETCH body #%u → %u bytes\n", body_seq, body.length);
        var preview = body.length > 400 ? body.substring (0, 400) + "\n…" : body;
        stdout.printf ("---- body preview ----\n%s\n----------------------\n", preview);

        client.logout ();
        stdout.printf ("OK — IMAP spike succeeded without Camel.\n");
        return 0;
    } catch (GLib.Error e) {
        stderr.printf ("IMAP spike failed: %s\n", e.message);
        return 1;
    }
}
