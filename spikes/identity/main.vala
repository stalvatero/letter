/**
 * Letter Identity spike — add/list/remove IMAP accounts on disk + libsecret.
 * No Camel, no GOA. Does not open mail yet (engine / Camel bridge next).
 *
 *   letter-identity-spike list
 *   letter-identity-spike add-imap   # uses LETTER_IDENTITY_* env
 *   letter-identity-spike remove <id>
 */
private static int main (string[] args) {
    if (args.length < 2) {
        print_usage ();
        return 2;
    }

    var cmd = args[1];
    try {
        if (cmd == "list")
            return cmd_list ();
        if (cmd == "add-imap")
            return cmd_add_imap ();
        if (cmd == "remove" && args.length >= 3)
            return cmd_remove (args[2]);
        print_usage ();
        return 2;
    } catch (Error e) {
        stderr.printf ("Identity spike failed: %s\n", e.message);
        return 1;
    }
}

private static void print_usage () {
    stderr.printf (
        "Usage:\n" +
        "  letter-identity-spike list\n" +
        "  letter-identity-spike add-imap\n" +
        "  letter-identity-spike remove <id>\n\n" +
        "add-imap env:\n" +
        "  LETTER_IDENTITY_EMAIL (required)\n" +
        "  LETTER_IDENTITY_PASS (required) — stored in libsecret only\n" +
        "  LETTER_IDENTITY_NAME (optional display name)\n" +
        "  LETTER_IDENTITY_USER (optional; default = email)\n" +
        "  LETTER_IDENTITY_IMAP_HOST (default imap.gmail.com)\n" +
        "  LETTER_IDENTITY_IMAP_PORT (default 993)\n" +
        "  LETTER_IDENTITY_SMTP_HOST (optional)\n" +
        "  LETTER_IDENTITY_SMTP_PORT (default 465)\n"
    );
}

private static int cmd_list () throws Error {
    var catalog = Mail.IdentityCatalog.load ();
    stdout.printf ("Catalog: %s\n", Mail.IdentityCatalog.path ());
    stdout.printf ("Accounts: %u\n", catalog.accounts.length);
    for (uint i = 0; i < catalog.accounts.length; i++) {
        var a = catalog.accounts[i];
        string secret = "no";
        try {
            var p = Mail.IdentitySecrets.lookup_password (a.id);
            if (p != null && p.length > 0) {
                secret = "yes";
                Secret.password_wipe (p);
            }
        } catch (Error e) {
            secret = "error";
        }
        stdout.printf (
            "  %s  %s <%s>  imap=%s:%u  secret=%s\n",
            a.id,
            a.display_name,
            a.email,
            a.imap_host,
            a.imap_port,
            secret
        );
    }
    return 0;
}

private static int cmd_add_imap () throws Error {
    var email = Environment.get_variable ("LETTER_IDENTITY_EMAIL");
    var pass = Environment.get_variable ("LETTER_IDENTITY_PASS");
    if (email == null || email.length == 0 || pass == null || pass.length == 0) {
        stderr.printf ("Set LETTER_IDENTITY_EMAIL and LETTER_IDENTITY_PASS\n");
        return 2;
    }

    var name = Environment.get_variable ("LETTER_IDENTITY_NAME") ?? email;
    var user = Environment.get_variable ("LETTER_IDENTITY_USER") ?? email;
    var host = Environment.get_variable ("LETTER_IDENTITY_IMAP_HOST") ?? "imap.gmail.com";
    var port_s = Environment.get_variable ("LETTER_IDENTITY_IMAP_PORT");
    uint port = 993;
    if (port_s != null && port_s.length > 0) {
        uint64 p = 0;
        if (uint64.try_parse (port_s, out p))
            port = (uint) p;
    }
    var smtp_host = Environment.get_variable ("LETTER_IDENTITY_SMTP_HOST");
    var smtp_port_s = Environment.get_variable ("LETTER_IDENTITY_SMTP_PORT");
    uint smtp_port = 465;
    if (smtp_port_s != null && smtp_port_s.length > 0) {
        uint64 p = 0;
        if (uint64.try_parse (smtp_port_s, out p))
            smtp_port = (uint) p;
    }

    var catalog = Mail.IdentityCatalog.load ();
    var acc = catalog.add_imap (
        email, name, user, host, port, true,
        smtp_host, smtp_port, true
    );
    catalog.save ();
    Mail.IdentitySecrets.store_password (
        acc.id,
        "Letter mail: %s".printf (email),
        pass
    );
    Secret.password_wipe (pass);

    stdout.printf ("Added Identity IMAP account\n");
    stdout.printf ("  id:    %s\n", acc.id);
    stdout.printf ("  email: %s\n", acc.email);
    stdout.printf ("  imap:  %s:%u\n", acc.imap_host, acc.imap_port);
    stdout.printf ("  file:  %s\n", Mail.IdentityCatalog.path ());
    stdout.printf ("  secret: libsecret schema io.github.stalvatero.Letter.Identity\n");
    stdout.printf ("OK — Identity catalog write succeeded (mail open = next step).\n");
    return 0;
}

private static int cmd_remove (string id) throws Error {
    var catalog = Mail.IdentityCatalog.load ();
    if (!catalog.remove_by_id (id)) {
        stderr.printf ("No account with id %s\n", id);
        return 1;
    }
    catalog.save ();
    try {
        Mail.IdentitySecrets.clear_password (id);
    } catch (Error e) {
        warning ("Could not clear secret: %s", e.message);
    }
    stdout.printf ("Removed %s\n", id);
    return 0;
}
