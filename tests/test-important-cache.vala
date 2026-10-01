void main () {
    try {
        var cache_dir = DirUtils.make_tmp ("letter-important-cache-XXXXXX");
        Environment.set_variable ("XDG_CACHE_HOME", cache_dir, true);

        var account = new Mail.Account () { uid = "test-account", kind = Mail.AccountKind.GOOGLE };
        var folder = new Mail.Folder () {
            name = "Important",
            full_name = "[Gmail]/Important",
        };
        var previous = messages (7773);
        var empty = messages (0);
        var remaining = messages (3);
        var path = Mail.MailSession.header_list_cache_file (account.uid, folder.full_name);
        var completed = Mail.MailSession.trust_important_refresh (account, folder, true);
        var incomplete = Mail.MailSession.trust_important_refresh (account, folder, false);
        assert (completed);
        assert (!incomplete);

        assert (Mail.Window.reconcile_header_lists (previous, empty, 7773, completed) == empty);
        assert (Mail.Window.reconcile_header_lists (previous, remaining, 7773, completed) == remaining);
        assert (Mail.Window.reconcile_header_lists (previous, empty, 7773, incomplete).length == 7773);
        assert (Mail.Window.reconcile_header_lists (previous, remaining, 7773, incomplete).length == 7773);

        var tip = messages (1);
        tip[0].uid = "new-message";
        var kept = Mail.Window.reconcile_header_lists (previous, tip, 7773, incomplete);
        assert (kept.length == 7774);
        assert (kept[7773] == tip[0]);
        assert (Mail.Window.reconcile_header_lists (messages (10), remaining, 10, false) == remaining);
        assert (Mail.Window.reconcile_header_lists (previous, messages (7500), 7773, false).length == 7500);
        assert (Mail.Window.reconcile_header_lists (previous, remaining, 3, false) == remaining);

        Mail.Window.save_header_list_cache (account.uid, folder.full_name, folder.name, previous);
        FileUtils.set_contents (path + ".highwater", "7773\n");
        Mail.Window.save_header_list_cache (account.uid, folder.full_name, folder.name, remaining);
        assert (Mail.Window.load_header_list_cache (account, folder).length == 7773);
        string high_water;
        FileUtils.get_contents (path + ".highwater", out high_water);
        assert (high_water == "7773\n");
        Mail.Window.save_header_list_cache (account.uid, folder.full_name, folder.name, remaining, completed);
        var loaded = Mail.Window.load_header_list_cache (account, folder);
        assert (loaded.length == 3);
        assert (loaded[0].uid == remaining[0].uid);
        FileUtils.get_contents (path + ".highwater", out high_water);
        assert (high_water == "3\n");
        Mail.Window.save_header_list_cache (account.uid, folder.full_name, folder.name, previous);
        FileUtils.set_contents (path + ".highwater", "7773\n");
        Mail.Window.save_header_list_cache (account.uid, folder.full_name, folder.name, empty, completed);
        assert (Mail.Window.load_header_list_cache (account, folder).length == 0);
        FileUtils.get_contents (path + ".highwater", out high_water);
        assert (high_water == "0\n");

        var inbox = new Mail.Folder () { name = "Inbox", full_name = "INBOX" };
        assert (!Mail.MailSession.trust_important_refresh (account, inbox, true));
        account.kind = Mail.AccountKind.MICROSOFT;
        assert (!Mail.MailSession.trust_important_refresh (account, folder, true));
        account.kind = Mail.AccountKind.EXCHANGE;
        assert (!Mail.MailSession.trust_important_refresh (account, folder, true));
        account.kind = Mail.AccountKind.IMAP;
        assert (!Mail.MailSession.trust_important_refresh (account, folder, true));

        FileUtils.unlink (path);
        FileUtils.unlink (path + ".highwater");
        DirUtils.remove (Path.get_dirname (path));
        DirUtils.remove (Mail.MailSession.header_list_cache_dir ());
        DirUtils.remove (Path.build_filename (cache_dir, "letter"));
        DirUtils.remove (cache_dir);
    } catch (Error e) {
        error ("Important cache test failed: %s", e.message);
    }
}

GenericArray<Mail.Message> messages (uint count) {
    var result = new GenericArray<Mail.Message> ();
    for (uint i = 0; i < count; i++) {
        result.add (new Mail.Message () {
            uid = i.to_string (),
            msgid_hash = i + 1,
            subject = "Test message",
            from = "sender@example.com",
            to = "recipient@example.com",
            cc = "",
            important = true,
        });
    }
    return result;
}
