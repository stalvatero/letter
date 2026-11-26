/* Local Outbox send queue.
 * Kept off the Archive/Inbox Camel sync pump so send never waits behind body prefetch. */

public class Mail.PendingMail : Object {
    public string id { get; set; }
    public string account_uid { get; set; }
    public string to { get; set; default = ""; }
    public string cc { get; set; default = ""; }
    public string bcc { get; set; default = ""; }
    public string subject { get; set; default = ""; }
    public string plain { get; set; default = ""; }
    public string html { get; set; default = ""; }
    public bool is_forward { get; set; }
    public string? reply_message_id { get; set; }
    public string? reply_in_reply_to { get; set; }
    /** Graph/Camel parent uid for createForward/createReply threading. */
    public string? reply_uid { get; set; }
    public string? reply_conversation_id { get; set; }
    public uint attempts { get; set; }
    public int64 next_attempt_us { get; set; }
    public string? last_error { get; set; }
    public int64 updated_us { get; set; }
    public bool high_priority { get; set; }
    public GenericArray<string> attachment_names = new GenericArray<string> ();

    public string display_subject {
        owned get {
            if (this.subject != null && this.subject.strip ().length > 0)
                return this.subject.strip ();
            return _("(No subject)");
        }
    }
}

public class Mail.OutboxStore : Object {
    public const uint RETRY_SECONDS = 5;
    public const uint FAIL_NOTIFY_AFTER = 1;

    private static int64 wall_tick () {
        return get_real_time ();
    }

    public signal void changed ();
    public signal void item_sent (PendingMail item);
    public signal void item_needs_attention (PendingMail item, string message);

    private MailBackend session;
    private bool pump_running;
    private uint pump_source;
    private string? active_id;
    private HashTable<string, uint8> attention_shown;

    public OutboxStore (MailBackend session) {
        this.session = session;
        this.attention_shown = new HashTable<string, uint8> (str_hash, str_equal);
    }

    public uint pending_count {
        get { return list_outbox_ids ().length; }
    }

    public string? active_send_id {
        get { return this.active_id; }
    }

    public static string outbox_root () {
        return Path.build_filename (Environment.get_user_data_dir (), "letter", "outbox");
    }

    public static string new_id () {
        return Uuid.string_random ();
    }

    public void start () {
        ensure_dirs ();
        /* Legacy crash-recovery path; drafts now live in Camel Drafts. */
        delete_tree (Path.build_filename (Environment.get_user_data_dir (), "letter", "compose-autosave"));
        schedule_pump (1);
    }

    public void stop () {
        if (this.pump_source != 0) {
            Source.remove (this.pump_source);
            this.pump_source = 0;
        }
    }

    public void request_send_now (string? id = null) {
        if (id != null) {
            var item = load_outbox_item (id);
            if (item != null) {
                item.next_attempt_us = 0;
                save_outbox_meta (item);
            }
        }
        schedule_pump (0);
    }

    /* —— Outbox —— */

    public async string enqueue_outbox (
        Account account,
        string to,
        string cc,
        string bcc,
        string subject,
        string plain,
        string html,
        bool is_forward,
        MessageContent? thread_of,
        GenericArray<Attachment> attachments,
        bool high_priority = false
    ) throws Error {
        ensure_dirs ();
        var id = new_id ();
        var dir = Path.build_filename (outbox_root (), id);
        File.new_for_path (dir).make_directory_with_parents ();

        var item = new PendingMail () {
            id = id,
            account_uid = account.source_uid ?? account.uid,
            to = to,
            cc = cc ?? "",
            bcc = bcc ?? "",
            subject = subject ?? "",
            plain = plain ?? "",
            html = html ?? "",
            is_forward = is_forward,
            high_priority = high_priority,
            attempts = 0,
            next_attempt_us = 0,
            updated_us = wall_tick (),
        };
        if (thread_of != null) {
            item.reply_message_id = thread_of.message_id;
            item.reply_in_reply_to = thread_of.in_reply_to ?? thread_of.message_id;
            if (thread_of.uid != null && thread_of.uid.length > 0)
                item.reply_uid = thread_of.uid;
            if (thread_of.conversation_id != null && thread_of.conversation_id.length > 0)
                item.reply_conversation_id = thread_of.conversation_id;
        }
        write_bodies (dir, item.plain, item.html);
        item.attachment_names = yield snapshot_attachments (dir, attachments);
        save_outbox_meta (item);
        changed ();
        schedule_pump (0);
        return id;
    }

    public GenericArray<PendingMail> list_outbox () {
        return list_items (outbox_root ());
    }

    public void delete_outbox_item (string id) {
        delete_tree (Path.build_filename (outbox_root (), id));
        this.attention_shown.remove (id);
        changed ();
    }

    public PendingMail? load_outbox_item (string id) {
        return load_item_dir (Path.build_filename (outbox_root (), id));
    }

    public GenericArray<Attachment> load_outbox_attachments (PendingMail item) {
        return load_attachments_from (outbox_root (), item);
    }

    private GenericArray<Attachment> load_attachments_from (string root, PendingMail item) {
        var list = new GenericArray<Attachment> ();
        var dir = Path.build_filename (root, item.id);
        for (uint i = 0; i < item.attachment_names.length; i++) {
            var name = item.attachment_names[i];
            var path = Path.build_filename (dir, "att-%u".printf (i));
            try {
                uint8[] data;
                FileUtils.get_data (path, out data);
                list.add (new Attachment () {
                    filename = name,
                    mime_type = "application/octet-stream",
                    data = new Bytes (data),
                    file = File.new_for_path (path),
                });
            } catch (Error e) {
                warning ("Pending attachment missing %s: %s", name, e.message);
            }
        }
        return list;
    }

    public MessageContent? thread_content_for (PendingMail item) {
        var has_msgid = item.reply_message_id != null && item.reply_message_id.length > 0;
        var has_uid = item.reply_uid != null && item.reply_uid.length > 0;
        var has_conv = item.reply_conversation_id != null
            && item.reply_conversation_id.length > 0;
        if (!has_msgid && !has_uid && !has_conv)
            return null;
        return new MessageContent () {
            uid = has_uid ? item.reply_uid : "outbox-thread",
            message_id = item.reply_message_id,
            in_reply_to = item.reply_in_reply_to,
            conversation_id = item.reply_conversation_id,
        };
    }

    private void schedule_pump (uint delay_seconds) {
        if (this.pump_source != 0) {
            Source.remove (this.pump_source);
            this.pump_source = 0;
        }
        if (delay_seconds == 0) {
            this.pump_source = Idle.add (() => {
                this.pump_source = 0;
                pump.begin ();
                return Source.REMOVE;
            });
            return;
        }
        this.pump_source = Timeout.add_seconds (uint.min (delay_seconds, 120), () => {
            this.pump_source = 0;
            pump.begin ();
            return Source.REMOVE;
        });
    }

    private async void pump () {
        if (this.pump_running)
            return;
        this.pump_running = true;
        try {
            while (true) {
                var next = pick_due_item ();
                if (next == null) {
                    var soon = seconds_until_next ();
                    if (soon >= 0)
                        schedule_pump ((uint) soon.clamp (1, 120));
                    break;
                }

                this.active_id = next.id;
                changed ();
                var ok = yield try_send_item (next);
                this.active_id = null;
                if (ok) {
                    this.attention_shown.remove (next.id);
                    delete_outbox_item (next.id);
                    item_sent (next);
                    changed ();
                    continue;
                }

                next.attempts++;
                next.next_attempt_us = wall_tick ()
                    + (int64) retry_delay_seconds (next.attempts) * 1000 * 1000;
                save_outbox_meta (next);
                changed ();

                if (next.attempts >= FAIL_NOTIFY_AFTER && !this.attention_shown.contains (next.id)) {
                    this.attention_shown.set (next.id, 1);
                    var msg = next.last_error ?? _("Sending failed");
                    item_needs_attention (next, msg);
                }
                schedule_pump (retry_delay_seconds (next.attempts));
                break;
            }
        } finally {
            this.pump_running = false;
            this.active_id = null;
        }
    }

    private async bool try_send_item (PendingMail item) {
        Account? account = null;
        var app = GLib.Application.get_default () as Application;
        if (app != null) {
            for (uint i = 0; i < app.accounts.items.get_n_items (); i++) {
                var a = app.accounts.items.get_item (i) as Account;
                if (a == null)
                    continue;
                var uid = a.source_uid ?? a.uid;
                if (uid == item.account_uid) {
                    account = a;
                    break;
                }
            }
        }
        if (account == null || !account.has_mail) {
            item.last_error = _("The sending account is unavailable.");
            return false;
        }

        var attachments = load_outbox_attachments (item);
        var thread = thread_content_for (item);
        Utils.sync_log ("outbox send “%s” attempt %u".printf (item.display_subject, item.attempts + 1));
        try {
            yield this.session.send_message (
                account,
                item.to,
                item.cc.length > 0 ? item.cc : null,
                item.subject,
                item.plain,
                item.html.length > 0 ? item.html : null,
                item.bcc.length > 0 ? item.bcc : null,
                attachments,
                thread,
                null,
                item.is_forward,
                item.high_priority
            );
            Utils.sync_log ("outbox send ok “%s”".printf (item.display_subject));
            return true;
        } catch (Error e) {
            item.last_error = Utils.friendly_send_error (e);
            Utils.sync_log ("outbox send FAILED “%s”: %s".printf (item.display_subject, e.message));
            return false;
        }
    }

    private static uint retry_delay_seconds (uint attempts) {
        if (attempts <= 1)
            return RETRY_SECONDS;
        if (attempts == 2)
            return 15;
        if (attempts <= 5)
            return 60;
        return 120;
    }

    private PendingMail? pick_due_item () {
        var now = wall_tick ();
        PendingMail? best = null;
        var list = list_outbox ();
        for (uint i = 0; i < list.length; i++) {
            var item = list[i];
            if (item.next_attempt_us > now)
                continue;
            if (best == null || item.updated_us < best.updated_us)
                best = item;
        }
        return best;
    }

    private int seconds_until_next () {
        var now = wall_tick ();
        int64 soonest = -1;
        var list = list_outbox ();
        for (uint i = 0; i < list.length; i++) {
            var due = list[i].next_attempt_us;
            if (due <= now)
                return 0;
            var wait = (due - now) / (1000 * 1000);
            if (soonest < 0 || wait < soonest)
                soonest = wait;
        }
        return (int) soonest;
    }

    private GenericArray<string> list_outbox_ids () {
        var ids = new GenericArray<string> ();
        var root = outbox_root ();
        try {
            var dir = Dir.open (root);
            string? name;
            while ((name = dir.read_name ()) != null) {
                var path = Path.build_filename (root, name);
                if (FileUtils.test (path, FileTest.IS_DIR))
                    ids.add (name);
            }
        } catch (Error e) {
        }
        return ids;
    }

    private GenericArray<PendingMail> list_items (string root) {
        var list = new GenericArray<PendingMail> ();
        try {
            var dir = Dir.open (root);
            string? name;
            while ((name = dir.read_name ()) != null) {
                var item = load_item_dir (Path.build_filename (root, name));
                if (item != null)
                    list.add (item);
            }
        } catch (Error e) {
        }
        list.sort ((a, b) => {
            if (a.updated_us < b.updated_us)
                return 1;
            if (a.updated_us > b.updated_us)
                return -1;
            return 0;
        });
        return list;
    }

    private PendingMail? load_item_dir (string dir) {
        var meta_path = Path.build_filename (dir, "meta");
        if (!FileUtils.test (meta_path, FileTest.IS_REGULAR))
            return null;
        try {
            var key = new KeyFile ();
            key.load_from_file (meta_path, KeyFileFlags.NONE);
            var item = new PendingMail () {
                id = key.get_string ("mail", "id"),
                account_uid = key.get_string ("mail", "account"),
                to = key.get_string ("mail", "to"),
                cc = key.has_key ("mail", "cc") ? key.get_string ("mail", "cc") : "",
                bcc = key.has_key ("mail", "bcc") ? key.get_string ("mail", "bcc") : "",
                subject = key.has_key ("mail", "subject") ? key.get_string ("mail", "subject") : "",
                is_forward = key.has_key ("mail", "forward") && key.get_boolean ("mail", "forward"),
                high_priority = key.has_key ("mail", "high-priority") && key.get_boolean ("mail", "high-priority"),
                attempts = key.has_key ("mail", "attempts") ? key.get_integer ("mail", "attempts") : 0,
                next_attempt_us = key.has_key ("mail", "next") ? key.get_int64 ("mail", "next") : 0,
                updated_us = key.has_key ("mail", "updated") ? key.get_int64 ("mail", "updated") : 0,
                last_error = key.has_key ("mail", "error") ? key.get_string ("mail", "error") : null,
                reply_message_id = key.has_key ("mail", "reply-id") ? key.get_string ("mail", "reply-id") : null,
                reply_in_reply_to = key.has_key ("mail", "reply-irt") ? key.get_string ("mail", "reply-irt") : null,
                reply_uid = key.has_key ("mail", "reply-uid") ? key.get_string ("mail", "reply-uid") : null,
                reply_conversation_id = key.has_key ("mail", "reply-cid")
                    ? key.get_string ("mail", "reply-cid") : null,
            };
            try {
                string plain;
                FileUtils.get_contents (Path.build_filename (dir, "body.txt"), out plain);
                item.plain = plain;
            } catch (Error e) {
            }
            try {
                string html;
                FileUtils.get_contents (Path.build_filename (dir, "body.html"), out html);
                item.html = html;
            } catch (Error e) {
            }
            if (key.has_key ("mail", "attachments")) {
                var names = key.get_string_list ("mail", "attachments");
                for (uint i = 0; i < names.length; i++)
                    item.attachment_names.add (names[i]);
            }
            return item;
        } catch (Error e) {
            warning ("Could not read pending mail %s: %s", dir, e.message);
            return null;
        }
    }

    private void save_outbox_meta (PendingMail item) {
        save_meta (Path.build_filename (outbox_root (), item.id, "meta"), item);
    }

    private void save_meta (string path, PendingMail item) {
        var key = new KeyFile ();
        key.set_string ("mail", "id", item.id);
        key.set_string ("mail", "account", item.account_uid);
        key.set_string ("mail", "to", item.to ?? "");
        key.set_string ("mail", "cc", item.cc ?? "");
        key.set_string ("mail", "bcc", item.bcc ?? "");
        key.set_string ("mail", "subject", item.subject ?? "");
        key.set_boolean ("mail", "forward", item.is_forward);
        key.set_boolean ("mail", "high-priority", item.high_priority);
        key.set_integer ("mail", "attempts", (int) item.attempts);
        key.set_int64 ("mail", "next", item.next_attempt_us);
        key.set_int64 ("mail", "updated", item.updated_us);
        if (item.last_error != null)
            key.set_string ("mail", "error", item.last_error);
        if (item.reply_message_id != null)
            key.set_string ("mail", "reply-id", item.reply_message_id);
        if (item.reply_in_reply_to != null)
            key.set_string ("mail", "reply-irt", item.reply_in_reply_to);
        if (item.reply_uid != null)
            key.set_string ("mail", "reply-uid", item.reply_uid);
        if (item.reply_conversation_id != null)
            key.set_string ("mail", "reply-cid", item.reply_conversation_id);
        if (item.attachment_names.length > 0) {
            string[] names = {};
            for (uint i = 0; i < item.attachment_names.length; i++)
                names += item.attachment_names[i];
            key.set_string_list ("mail", "attachments", names);
        }
        try {
            key.save_to_file (path);
        } catch (Error e) {
            warning ("Could not write pending mail meta: %s", e.message);
        }
    }

    private static void write_bodies (string dir, string plain, string html) throws Error {
        FileUtils.set_contents (Path.build_filename (dir, "body.txt"), plain ?? "");
        FileUtils.set_contents (Path.build_filename (dir, "body.html"), html ?? "");
    }

    private async GenericArray<string> snapshot_attachments (string dir, GenericArray<Attachment> attachments) throws Error {
        var names = new GenericArray<string> ();
        for (uint i = 0; i < attachments.length; i++) {
            var att = attachments[i];
            var name = att.save_filename;
            names.add (name);
            var dest = Path.build_filename (dir, "att-%u".printf (i));
            if (att.data != null && att.data.get_size () > 0) {
                FileUtils.set_data (dest, att.data.get_data ());
            } else if (att.file != null) {
                yield att.file.copy_async (File.new_for_path (dest), FileCopyFlags.OVERWRITE, Priority.DEFAULT, null, null);
            } else {
                FileUtils.set_contents (dest, "");
            }
            Idle.add (snapshot_attachments.callback);
            yield;
        }
        return names;
    }

    private void ensure_dirs () {
        try {
            File.new_for_path (outbox_root ()).make_directory_with_parents ();
        } catch (Error e) {
            if (!(e is IOError.EXISTS))
                warning ("outbox dir: %s", e.message);
        }
    }

    private static void delete_tree (string path) {
        try {
            var file = File.new_for_path (path);
            if (!file.query_exists ())
                return;
            delete_recursive (file);
        } catch (Error e) {
            warning ("Could not delete %s: %s", path, e.message);
        }
    }

    private static void delete_recursive (File file) throws Error {
        var type = file.query_file_type (FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
        if (type == FileType.DIRECTORY) {
            var enumerator = file.enumerate_children ("standard::name", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info;
            while ((info = enumerator.next_file ()) != null)
                delete_recursive (file.get_child (info.get_name ()));
        }
        file.delete ();
    }
}
