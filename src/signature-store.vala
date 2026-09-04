public class Mail.MailSignature : Object {
    public string name { get; set; default = ""; }
    public string html { get; set; default = ""; }

    public MailSignature (string name, string html) {
        this.name = name;
        this.html = html;
    }

    public string compose_html () {
        var body = html_body ().strip ();
        body = strip_leading_mark (body);
        if (body.length == 0)
            return "";
        return "<div class=\"mail-signature-mark\">--</div>" + body;
    }

    public string html_body () {
        if (looks_like_html (this.html))
            return this.html;
        return Markup.escape_text (this.html).replace ("\n", "<br>\n");
    }

    public static bool looks_like_html (string text) {
        var down = text.down ();
        return down.contains ("<br")
            || down.contains ("<div")
            || down.contains ("<p")
            || down.contains ("<span")
            || down.contains ("<a ")
            || down.contains ("<img")
            || down.contains ("<b>")
            || down.contains ("<i>")
            || down.contains ("<strong")
            || down.contains ("<em");
    }

    private static string strip_leading_mark (string html) {
        var text = html.strip ();
        string[] prefixes = {
            "<div class=\"mail-signature-mark\">--</div>",
            "<div class=\"mail-signature-mark\">-- </div>",
            "<p>--</p>",
            "<div>--</div>",
            "--<br>",
            "--<br/>",
            "--<br />",
        };
        foreach (var prefix in prefixes) {
            if (text.down ().has_prefix (prefix))
                return text.substring (prefix.length).strip ();
        }
        if (text.has_prefix ("--\n"))
            return text.substring (3).strip ();
        if (text.has_prefix ("-- "))
            return text.substring (3).strip ();
        if (text == "--")
            return "";
        return text;
    }
}

public class Mail.SignatureStore : Object {
    private Settings settings;

    public SignatureStore (Settings settings) {
        this.settings = settings;
    }

    public void migrate_if_needed (AccountStore accounts) {
        if (this.settings.get_boolean ("signatures-migrated"))
            return;

        var legacy = this.settings.get_value ("compose-signatures");
        if (legacy.n_children () == 0) {
            this.settings.set_boolean ("signatures-migrated", true);
            return;
        }

        var last = this.settings.get_string ("compose-signature-name");
        var copied = new GenericArray<MailSignature> ();
        for (size_t i = 0; i < legacy.n_children (); i++) {
            string name;
            string body;
            legacy.get_child (i, "(ss)", out name, out body);
            copied.add (new MailSignature (name, body));
        }

        for (uint i = 0; i < accounts.items.get_n_items (); i++) {
            var account = accounts.items.get_item (i) as Account;
            if (account == null || !account.has_mail || account.kind == AccountKind.LOCAL)
                continue;
            var key = account.signature_key;
            if (key.length == 0 || list (key).length > 0)
                continue;
            replace (key, copied);
            if (last.length > 0)
                set_default_name (key, last);
        }

        this.settings.set_boolean ("signatures-migrated", true);
    }

    public GenericArray<MailSignature> list (string account_key) {
        var listed = new GenericArray<MailSignature> ();
        if (account_key.length == 0)
            return listed;

        var variant = this.settings.get_value ("account-signatures");
        for (size_t i = 0; i < variant.n_children (); i++) {
            string key;
            string name;
            string html;
            variant.get_child (i, "(sss)", out key, out name, out html);
            if (key != account_key)
                continue;
            listed.add (new MailSignature (name, html));
        }
        return listed;
    }

    public void replace (string account_key, GenericArray<MailSignature> listed) {
        var builder = new VariantBuilder (new VariantType ("a(sss)"));
        var variant = this.settings.get_value ("account-signatures");
        for (size_t i = 0; i < variant.n_children (); i++) {
            string key;
            string name;
            string html;
            variant.get_child (i, "(sss)", out key, out name, out html);
            if (key == account_key)
                continue;
            builder.add ("(sss)", key, name, html);
        }
        for (uint i = 0; i < listed.length; i++)
            builder.add ("(sss)", account_key, listed[i].name, listed[i].html);
        this.settings.set_value ("account-signatures", builder.end ());
    }

    public void upsert (string account_key, MailSignature signature, string? old_name) {
        var listed = list (account_key);
        var found = false;
        var target = old_name != null && old_name.length > 0 ? old_name : signature.name;
        for (uint i = 0; i < listed.length; i++) {
            if (listed[i].name != target)
                continue;
            listed[i] = signature;
            found = true;
            break;
        }
        if (!found)
            listed.add (signature);
        replace (account_key, listed);

        var current = default_name (account_key);
        if (old_name != null && old_name.length > 0 && current == old_name && old_name != signature.name)
            set_default_name (account_key, signature.name);
        else if (current.length == 0 && listed.length == 1)
            set_default_name (account_key, signature.name);
    }

    public void remove (string account_key, string name) {
        var listed = list (account_key);
        for (uint i = 0; i < listed.length; i++) {
            if (listed[i].name != name)
                continue;
            listed.remove_index (i);
            break;
        }
        replace (account_key, listed);
        if (default_name (account_key) == name)
            set_default_name (account_key, "");
    }

    public string default_name (string account_key) {
        var variant = this.settings.get_value ("account-signature-choice");
        for (size_t i = 0; i < variant.n_children (); i++) {
            string key;
            string name;
            variant.get_child (i, "(ss)", out key, out name);
            if (key == account_key)
                return name;
        }
        return "";
    }

    public void set_default_name (string account_key, string name) {
        var builder = new VariantBuilder (new VariantType ("a(ss)"));
        var variant = this.settings.get_value ("account-signature-choice");
        for (size_t i = 0; i < variant.n_children (); i++) {
            string key;
            string selected;
            variant.get_child (i, "(ss)", out key, out selected);
            if (key == account_key)
                continue;
            builder.add ("(ss)", key, selected);
        }
        builder.add ("(ss)", account_key, name);
        this.settings.set_value ("account-signature-choice", builder.end ());
    }
}
