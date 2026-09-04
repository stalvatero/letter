public class Mail.Conversation : Object {
    public string id { get; private set; }
    public GenericArray<Message> messages { get; default = new GenericArray<Message> (); }
    public string? list_folder { get; set; }
    public string subject { get; private set; default = ""; }
    public string participants { get; private set; default = ""; }
    public string? preview { get; private set; }
    public int64 date { get; private set; }
    public int unread { get; private set; }
    public bool has_attachment { get; private set; }
    public bool flagged { get; private set; }
    public bool important { get; private set; }
    public bool seen {
        get {
            return this.unread == 0;
        }
    }

    public Message? latest {
        get {
            return this.messages.length > 0 ? this.messages[this.messages.length - 1] : null;
        }
    }

    public uint listed_count {
        get {
            uint n = 0;
            for (uint i = 0; i < this.messages.length; i++) {
                if (in_list_folder (this.messages[i]))
                    n++;
            }
            return n;
        }
    }

    public void add_message (Message message) {
        for (uint i = 0; i < this.messages.length; i++) {
            var existing = this.messages[i];
            if (existing.uid == message.uid
                && (existing.folder_full_name ?? "") == (message.folder_full_name ?? ""))
                return;
            if (!same_outgoing_send (existing, message))
                continue;
            if (message.is_placeholder)
                return;
            if (existing.is_placeholder)
                this.messages[i] = message;
            return;
        }

        this.messages.add (message);
    }

    public bool contains (string uid, string? folder_full_name) {
        for (uint i = 0; i < this.messages.length; i++) {
            if (this.messages[i].uid != uid)
                continue;
            if (folder_full_name != null && (this.messages[i].folder_full_name ?? "") != folder_full_name)
                continue;
            return true;
        }

        return false;
    }

    public bool remove_uid (string uid, string? folder_full_name) {
        for (uint i = 0; i < this.messages.length; i++) {
            if (this.messages[i].uid != uid)
                continue;
            if (folder_full_name != null && (this.messages[i].folder_full_name ?? "") != folder_full_name)
                continue;
            this.messages.remove_index (i);
            refresh ();
            return true;
        }

        return false;
    }

    public bool relocate (string uid, string? from_folder, Folder destination, string? new_uid) {
        for (uint i = 0; i < this.messages.length; i++) {
            var message = this.messages[i];
            if (message.uid != uid)
                continue;
            if (from_folder != null && (message.folder_full_name ?? "") != from_folder)
                continue;
            apply_folder (message, destination, new_uid);
            refresh ();
            return true;
        }

        return false;
    }

    public static void apply_folder (Message message, Folder destination, string? new_uid) {
        message.folder_full_name = destination.full_name;
        message.folder_name = destination.name;
        message.outgoing = destination.kind == FolderKind.SENT
            || destination.kind == FolderKind.DRAFTS
            || destination.kind == FolderKind.OUTBOX;
        if (new_uid != null && new_uid.length > 0)
            message.uid = new_uid;
    }

    public Message? pick_open () {
        Message? last_received = null;
        Message? last_listed = null;
        for (uint i = 0; i < this.messages.length; i++) {
            if (!in_list_folder (this.messages[i]))
                continue;
            last_listed = this.messages[i];
            if (!this.messages[i].outgoing)
                last_received = this.messages[i];
        }

        return last_received ?? last_listed ?? this.latest;
    }

    public Message? pick_flagged (Message? after = null) {
        var skip = after != null;
        for (int i = (int) this.messages.length - 1; i >= 0; i--) {
            var message = this.messages[i];
            if (!in_list_folder (message) || message.is_placeholder)
                continue;
            if (skip && after != null
                && message.uid == after.uid
                && (message.folder_full_name ?? "") == (after.folder_full_name ?? "")) {
                skip = false;
                continue;
            }
            if (!message.flagged || skip)
                continue;
            return message;
        }

        return null;
    }

    public bool in_list_folder (Message message) {
        if (this.list_folder == null || this.list_folder.length == 0)
            return true;

        return (message.folder_full_name ?? "") == this.list_folder;
    }

    public void refresh () {
        this.messages.sort ((a, b) => {
            if (a.date < b.date)
                return -1;
            if (a.date > b.date)
                return 1;
            return 0;
        });

        Message? listed_last = null;
        for (uint i = 0; i < this.messages.length; i++) {
            if (in_list_folder (this.messages[i]))
                listed_last = this.messages[i];
        }

        var last = listed_last ?? this.latest;
        this.subject = last != null ? display_subject (last.subject) : _("(No subject)");
        this.preview = last != null ? last.preview : null;
        this.date = last != null ? last.date : 0;
        this.has_attachment = false;
        this.flagged = false;
        this.important = false;
        this.unread = 0;
        var names = new GenericArray<string> ();
        var seen_names = new HashTable<string, uint8> (str_hash, str_equal);
        var first = this.messages.length > 0 ? this.messages[0] : null;
        this.id = thread_id (this.messages);
        if (this.id.length == 0 && first != null)
            this.id = "uid\n%s\n%s".printf (first.folder_full_name ?? "", first.uid);

        for (int i = (int) this.messages.length - 1; i >= 0; i--) {
            var message = this.messages[i];
            if (message.has_attachment)
                this.has_attachment = true;
            if (!in_list_folder (message))
                continue;
            if (message.flagged)
                this.flagged = true;
            if (message.important)
                this.important = true;
            if (!message.seen)
                this.unread++;

            var name = message.list_address;
            if (name == null || name.length == 0)
                name = message.from;
            var key = name.casefold ();
            if (seen_names.contains (key))
                continue;
            seen_names.set (key, 1);
            names.add (name);
        }

        if (this.id.length == 0 && last != null)
            this.id = "uid\n%s\n%s".printf (last.folder_full_name ?? "", last.uid);

        if (names.length == 0) {
            this.participants = "";
        } else if (names.length <= 3) {
            var parts = new string[names.length];
            for (uint i = 0; i < names.length; i++)
                parts[i] = names[i];
            this.participants = string.joinv (", ", parts);
        } else {
            this.participants = _("%s, %s +%u").printf (names[0], names[1], names.length - 2);
        }

        notify_property ("subject");
        notify_property ("participants");
        notify_property ("preview");
        notify_property ("date");
        notify_property ("unread");
        notify_property ("has-attachment");
        notify_property ("seen");
    }

    public void prefer_preview (Message message) {
        if (message.preview != null && message.preview.length > 0)
            this.preview = message.preview;
        notify_property ("preview");
    }

    public static Conversation from_message (Message message) {
        var conversation = new Conversation ();
        conversation.list_folder = message.folder_full_name;
        conversation.add_message (message);
        conversation.refresh ();
        return conversation;
    }

    public static GenericArray<Conversation> as_singles (GenericArray<Message> messages) {
        var conversations = new GenericArray<Conversation> ();
        for (uint i = 0; i < messages.length; i++)
            conversations.add (from_message (messages[i]));
        return conversations;
    }

    public static GenericArray<Conversation> group (
        GenericArray<Message> primary,
        GenericArray<Message>? extras
    ) {
        var all = new GenericArray<Message> ();
        var primary_keys = new HashTable<string, uint8> (str_hash, str_equal);
        for (uint i = 0; i < primary.length; i++) {
            primary_keys.set (message_key (primary[i]), 1);
            all.add (primary[i]);
        }
        if (extras != null) {
            for (uint i = 0; i < extras.length; i++) {
                var message = extras[i];
                if (primary_keys.contains (message_key (message)))
                    continue;
                all.add (message);
            }
        }

        var n = all.length;
        var sets = new ThreadUnion ((int) n);
        var hash_owner = new HashTable<string, int> (str_hash, str_equal);
        var key_owner = new HashTable<string, int> (str_hash, str_equal);

        for (int i = 0; i < (int) n; i++) {
            var message = all[i];
            // Every link (Message-ID, References, Conversation-ID, Thread-Index)
            // is gated by normalized subject. "Reply all" + changed subject starts
            // a new conversation; later replies to that mail stay with the new one.
            var subject = normalize_subject (message.subject);
            touch_hash (sets, hash_owner, message.msgid_hash, subject, i);
            var refs = message.msgid_refs;
            if (refs != null) {
                for (uint r = 0; r < refs.length; r++)
                    touch_hash (sets, hash_owner, refs[r], subject, i);
            }
            touch_key (sets, key_owner, conversation_subject_key (message), i);
        }

        for (int i = 0; i < (int) n; i++) {
            if (!all[i].is_placeholder)
                continue;
            for (int j = 0; j < (int) n; j++) {
                if (i == j)
                    continue;
                if (same_outgoing_send (all[i], all[j]))
                    sets.merge (i, j);
            }
        }

        var buckets = new HashTable<string, GenericArray<Message>> (str_hash, str_equal);
        for (int i = 0; i < (int) n; i++) {
            var key = sets.find (i).to_string ();
            var bucket = buckets.get (key);
            if (bucket == null) {
                bucket = new GenericArray<Message> ();
                buckets.set (key, bucket);
            }
            bucket.add (all[i]);
        }

        var conversations = new GenericArray<Conversation> ();
        string? list_folder = primary.length > 0 ? primary[0].folder_full_name : null;
        buckets.foreach ((key, bucket) => {
            var conversation = new Conversation ();
            conversation.list_folder = list_folder;
            for (uint i = 0; i < bucket.length; i++)
                conversation.add_message (bucket[i]);
            if (!contains_primary (conversation, primary_keys))
                return;
            conversation.refresh ();
            conversations.add (conversation);
        });

        conversations.sort ((a, b) => {
            if (a.date < b.date)
                return 1;
            if (a.date > b.date)
                return -1;
            return 0;
        });
        return conversations;
    }

    public static bool same_thread (Message a, Message b) {
        if (same_outgoing_send (a, b))
            return true;
        if (normalize_subject (a.subject) != normalize_subject (b.subject))
            return false;
        if (a.msgid_hash != 0 && a.msgid_hash == b.msgid_hash)
            return true;
        if (a.conversation_key != null && a.conversation_key.length > 0
            && a.conversation_key == b.conversation_key)
            return true;
        if (a.msgid_hash != 0 && hash_in_refs (b, a.msgid_hash))
            return true;
        if (b.msgid_hash != 0 && hash_in_refs (a, b.msgid_hash))
            return true;
        var refs = a.msgid_refs;
        if (refs == null)
            return false;
        for (uint i = 0; i < refs.length; i++) {
            if (refs[i] == 0)
                continue;
            if (b.msgid_hash == refs[i] || hash_in_refs (b, refs[i]))
                return true;
        }
        return false;
    }

    public static string display_subject (string? raw) {
        var text = raw ?? "";
        text = text.strip ();
        while (strip_reply_prefix (ref text)) {
        }

        text = text.strip ();
        return text.length > 0 ? text : _("(No subject)");
    }

    public static bool is_forward_subject (string? raw) {
        var text = (raw ?? "").strip ();
        if (text.has_prefix ("[") || text.has_prefix ("("))
            text = text.substring (1).strip ();

        var token = new StringBuilder ();
        int i = 0;
        unichar c;
        while (i < text.length) {
            var next = i;
            text.get_next_char (ref next, out c);
            if (!c.isalpha ())
                break;
            token.append_unichar (c.tolower ());
            i = next;
        }
        if (token.len == 0 || !is_forward_token (token.str))
            return false;

        while (i < text.length) {
            var next = i;
            text.get_next_char (ref next, out c);
            if (!c.isspace ())
                break;
            i = next;
        }
        if (i >= text.length)
            return false;
        var next = i;
        text.get_next_char (ref next, out c);
        return c == ':' || c == '[' || c == '(';
    }

    public static string normalize_subject (string? raw) {
        var text = display_subject (raw).casefold ();
        if (text == _("(No subject)").casefold ())
            return "";

        return collapse_spaces (text);
    }

    public static void prune_duplicate_sends (GenericArray<Message> messages) {
        for (int i = (int) messages.length - 1; i >= 0; i--) {
            if (!messages[i].is_placeholder)
                continue;
            for (uint j = 0; j < messages.length; j++) {
                if (j == i)
                    continue;
                if (!same_outgoing_send (messages[i], messages[j]))
                    continue;
                if (!messages[j].is_placeholder || j < i) {
                    messages.remove_index (i);
                    break;
                }
            }
        }
    }

    public static bool same_outgoing_send (Message a, Message b) {
        if (a.msgid_hash != 0 && a.msgid_hash == b.msgid_hash)
            return true;
        if (!a.outgoing || !b.outgoing)
            return false;
        if (!a.is_placeholder && !b.is_placeholder)
            return false;
        if (normalize_subject (a.subject) != normalize_subject (b.subject))
            return false;
        var delta = a.date > b.date ? a.date - b.date : b.date - a.date;
        return delta <= 180;
    }

    private static bool hash_in_refs (Message message, uint64 hash) {
        var refs = message.msgid_refs;
        if (hash == 0 || refs == null)
            return false;
        for (uint i = 0; i < refs.length; i++) {
            if (refs[i] == hash)
                return true;
        }
        return false;
    }

    private static string? conversation_subject_key (Message message) {
        var key = message.conversation_key;
        if (key == null || key.length == 0)
            return null;
        return "%s\n%s".printf (key, normalize_subject (message.subject));
    }

    private static void touch_hash (
        ThreadUnion sets,
        HashTable<string, int> owner,
        uint64 hash,
        string subject,
        int index
    ) {
        if (hash == 0)
            return;
        var key = "%s\n%s".printf (hash.to_string (), subject);
        if (owner.contains (key))
            sets.merge (index, owner.get (key));
        else
            owner.set (key, index);
    }

    private static void touch_key (ThreadUnion sets, HashTable<string, int> owner, string? key, int index) {
        if (key == null || key.length == 0)
            return;
        if (owner.contains (key))
            sets.merge (index, owner.get (key));
        else
            owner.set (key, index);
    }

    private static string thread_id (GenericArray<Message> messages) {
        string? conv = null;
        uint64 min_hash = 0;
        for (uint i = 0; i < messages.length; i++) {
            var message = messages[i];
            if (message.conversation_key != null && message.conversation_key.length > 0) {
                if (conv == null || message.conversation_key < conv)
                    conv = message.conversation_key;
            }
            if (message.msgid_hash != 0 && (min_hash == 0 || message.msgid_hash < min_hash))
                min_hash = message.msgid_hash;
        }
        if (conv != null)
            return "conv\n%s".printf (conv);
        if (min_hash != 0)
            return "msgid\n%s".printf (min_hash.to_string ());
        return "";
    }

    private static bool contains_primary (Conversation conversation, HashTable<string, uint8> primary_keys) {
        for (uint i = 0; i < conversation.messages.length; i++) {
            if (primary_keys.contains (message_key (conversation.messages[i])))
                return true;
        }

        return false;
    }

    private static string message_key (Message message) {
        return "%s\n%s".printf (message.folder_full_name ?? "", message.uid);
    }

    private static string collapse_spaces (string text) {
        var builder = new StringBuilder ();
        bool space = false;
        for (int i = 0; i < text.length; ) {
            unichar c;
            text.get_next_char (ref i, out c);
            if (c.isspace ()) {
                space = true;
                continue;
            }
            if (space && builder.len > 0)
                builder.append_c (' ');
            space = false;
            builder.append_unichar (c);
        }

        return builder.str;
    }

    private static bool strip_reply_prefix (ref string text) {
        int i = 0;
        unichar c;
        while (i < text.length) {
            var next = i;
            text.get_next_char (ref next, out c);
            if (!c.isspace ())
                break;
            i = next;
        }

        var token = new StringBuilder ();
        while (i < text.length) {
            var next = i;
            text.get_next_char (ref next, out c);
            if (!c.isalpha ())
                break;
            token.append_unichar (c.tolower ());
            i = next;
        }

        if (token.len == 0 || !is_reply_token (token.str))
            return false;

        while (i < text.length) {
            var next = i;
            text.get_next_char (ref next, out c);
            if (!c.isspace ())
                break;
            i = next;
        }

        if (i < text.length) {
            var next = i;
            text.get_next_char (ref next, out c);
            if (c == '[' || c == '(') {
                i = next;
                while (i < text.length) {
                    next = i;
                    text.get_next_char (ref next, out c);
                    if (!c.isdigit () && !c.isspace ())
                        break;
                    i = next;
                }
                if (i < text.length) {
                    next = i;
                    text.get_next_char (ref next, out c);
                    if (c == ']' || c == ')')
                        i = next;
                }
                while (i < text.length) {
                    next = i;
                    text.get_next_char (ref next, out c);
                    if (!c.isspace ())
                        break;
                    i = next;
                }
            }
        }

        if (i >= text.length)
            return false;

        var next = i;
        text.get_next_char (ref next, out c);
        if (c != ':')
            return false;

        text = text.substring (next).strip ();
        return true;
    }

    private static bool is_forward_token (string token) {
        switch (token) {
            case "fw":
            case "fwd":
            case "i":
            case "inoltra":
            case "wg":
                return true;
            default:
                return false;
        }
    }

    private static bool is_reply_token (string token) {
        switch (token) {
            case "re":
            case "r":
            case "ris":
            case "risposta":
            case "fw":
            case "fwd":
            case "i":
            case "inoltra":
            case "aw":
            case "sv":
            case "vs":
            case "wg":
            case "odp":
            case "rif":
            case "antw":
                return true;
            default:
                return false;
        }
    }
}

private class Mail.ThreadUnion {
    private int[] parent;
    private int[] rank;

    public ThreadUnion (int n) {
        this.parent = new int[n];
        this.rank = new int[n];
        for (int i = 0; i < n; i++)
            this.parent[i] = i;
    }

    public int find (int i) {
        if (this.parent[i] != i)
            this.parent[i] = find (this.parent[i]);
        return this.parent[i];
    }

    public void merge (int a, int b) {
        var ra = find (a);
        var rb = find (b);
        if (ra == rb)
            return;
        if (this.rank[ra] < this.rank[rb]) {
            this.parent[ra] = rb;
        } else if (this.rank[ra] > this.rank[rb]) {
            this.parent[rb] = ra;
        } else {
            this.parent[rb] = ra;
            this.rank[ra]++;
        }
    }
}

public class Mail.ThreadRow : Gtk.ListBoxRow {
    public Message message { get; private set; }
    public signal void context_pressed (double x, double y);

    private Gtk.Image kind_icon;
    private Gtk.Image attachment_icon;
    private Gtk.Image bookmark_icon;
    private Gtk.Image important_icon;
    private Gtk.Label from_label;
    private Gtk.Label date_label;
    private Gtk.Label folder_label;

    private GenericArray<string>? highlight_tokens;

    public ThreadRow (Message message, GenericArray<string>? highlights = null) {
        this.message = message;
        this.highlight_tokens = highlights;

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8) {
            hexpand = true,
            valign = Gtk.Align.CENTER,
        };
        this.kind_icon = new Gtk.Image ();
        this.kind_icon.add_css_class ("thread-kind-icon");
        this.from_label = new Gtk.Label ("") {
            hexpand = true,
            xalign = 0,
            ellipsize = Pango.EllipsizeMode.END,
            use_markup = false,
        };
        this.folder_label = new Gtk.Label ("") {
            use_markup = false,
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 14,
        };
        this.folder_label.add_css_class ("message-folder");
        this.folder_label.add_css_class ("dim-label");
        this.date_label = new Gtk.Label ("") {
            use_markup = false,
        };
        this.date_label.add_css_class ("dim-label");
        this.date_label.add_css_class ("numeric");
        this.attachment_icon = new Gtk.Image.from_icon_name ("mail-attachment-symbolic") {
            visible = false,
            tooltip_text = _("Attachment"),
        };
        this.attachment_icon.add_css_class ("dim-label");
        this.bookmark_icon = new Gtk.Image.from_icon_name ("user-bookmarks-symbolic") {
            visible = false,
            tooltip_text = _("Bookmarked"),
        };
        this.bookmark_icon.add_css_class ("bookmark-icon");
        this.important_icon = new Gtk.Image.from_icon_name ("mail-mark-important-symbolic") {
            visible = false,
            tooltip_text = _("Important"),
        };
        this.important_icon.add_css_class ("important-icon");
        box.append (this.kind_icon);
        box.append (this.from_label);
        box.append (this.folder_label);
        box.append (this.attachment_icon);
        box.append (this.bookmark_icon);
        box.append (this.important_icon);
        box.append (this.date_label);
        this.child = box;
        add_css_class ("thread-row");
        var click = new Gtk.GestureClick () {
            button = Gdk.BUTTON_SECONDARY,
        };
        click.pressed.connect ((n, x, y) => {
            context_pressed (x, y);
            click.set_state (Gtk.EventSequenceState.CLAIMED);
        });
        add_controller (click);
        update ();
    }

    public void update () {
        if (this.message.outgoing) {
            add_css_class ("outgoing");
            this.from_label.label = _("From me");
            this.from_label.attributes = null;
        } else {
            remove_css_class ("outgoing");
            var from = this.message.from != null && this.message.from.length > 0
                ? this.message.from
                : this.message.list_address;
            this.from_label.label = from;
            this.from_label.attributes = Utils.search_highlight_attrs (from, this.highlight_tokens);
        }
        if (this.message.outgoing && Conversation.is_forward_subject (this.message.subject)) {
            this.kind_icon.icon_name = "mail-forward-symbolic";
            this.kind_icon.tooltip_text = _("Forwarded");
        } else if (this.message.outgoing) {
            this.kind_icon.icon_name = "mail-send-symbolic";
            this.kind_icon.tooltip_text = _("Sent");
        } else {
            this.kind_icon.icon_name = "mail-read-symbolic";
            this.kind_icon.tooltip_text = _("Received");
        }
        this.date_label.label = Utils.format_message_date (this.message.date);
        var folder_name = this.message.folder_name;
        this.folder_label.label = folder_name ?? "";
        this.folder_label.visible = folder_name != null && folder_name.length > 0;
        this.attachment_icon.visible = this.message.has_attachment;
        this.bookmark_icon.visible = this.message.flagged;
        this.important_icon.visible = this.message.important;
        if (this.message.seen)
            remove_css_class ("unread");
        else
            add_css_class ("unread");
    }
}
