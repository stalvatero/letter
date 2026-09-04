public class Mail.Notifier : Object {
    public signal void activated (string kind, string token);
    public signal void fallback (string title, string body, string token, bool actions, bool sound);

    private DBusConnection? bus;
    private uint action_sub;
    private uint closed_sub;
    private HashTable<string, string> token_by_id;
    private HashTable<string, uint32> nid_by_token;
    private HashTable<string, string> token_by_key;
    private Settings settings;

    construct {
        this.token_by_id = new HashTable<string, string> (str_hash, str_equal);
        this.nid_by_token = new HashTable<string, uint32> (str_hash, str_equal);
        this.token_by_key = new HashTable<string, string> (str_hash, str_equal);
        this.settings = new Settings (Config.APP_ID);
    }

    public async void start () {
        if (this.bus != null)
            return;

        try {
            this.bus = yield Bus.get (BusType.SESSION, null);
        } catch (Error e) {
            warning ("Notifications bus: %s", e.message);
            return;
        }

        this.action_sub = this.bus.signal_subscribe (
            null,
            "org.freedesktop.Notifications",
            "ActionInvoked",
            "/org/freedesktop/Notifications",
            null,
            DBusSignalFlags.NONE,
            on_action_invoked
        );
        this.closed_sub = this.bus.signal_subscribe (
            null,
            "org.freedesktop.Notifications",
            "NotificationClosed",
            "/org/freedesktop/Notifications",
            null,
            DBusSignalFlags.NONE,
            on_notification_closed
        );
    }

    public string remember (string token) {
        var key = notification_key (token);
        this.token_by_key.set (key, token);
        return key;
    }

    public string resolve (string key_or_token) {
        if (key_or_token.contains ("\x1f"))
            return key_or_token;
        return this.token_by_key.get (key_or_token) ?? key_or_token;
    }

    public void show_new_mail (string title, string body, string token, bool sound = true) {
        remember (token);
        send (title, body, token, true, sound);
    }

    public void show_more (string title, string body, string token, bool sound = false) {
        remember (token);
        send (title, body, token, false, sound);
    }

    public void withdraw (string token) {
        var nid = this.nid_by_token.get (token);
        this.nid_by_token.remove (token);
        this.token_by_id.remove (nid.to_string ());
        if (this.bus == null || nid == 0)
            return;

        this.bus.call.begin (
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "CloseNotification",
            new Variant.tuple (new Variant[] { new Variant.uint32 (nid) }),
            null,
            DBusCallFlags.NONE,
            -1,
            null,
            null
        );
    }

    private void send (string title, string body, string token, bool actions, bool sound) {
        if (this.bus == null) {
            fallback (title, body, token, actions, sound);
            return;
        }

        string[] action_list;
        if (actions) {
            action_list = {
                "default", _("Open"),
                "archive", _("Archive"),
                "delete", _("Delete")
            };
        } else {
            action_list = {
                "default", _("Open")
            };
        }

        var hints = new VariantBuilder (new VariantType ("a{sv}"));
        hints.add ("{sv}", "urgency", new Variant.byte (1));
        hints.add ("{sv}", "category", new Variant.string ("email.arrived"));
        hints.add ("{sv}", "desktop-entry", new Variant.string (Config.APP_ID));
        add_sound_hint (hints, sound);

        var replaces = this.nid_by_token.get (token);
        var parameters = new Variant.tuple (new Variant[] {
            new Variant.string (Utils.app_display_name ()),
            new Variant.uint32 (replaces),
            new Variant.string (Config.APP_ID),
            new Variant.string (title),
            new Variant.string (body),
            new Variant.strv (action_list),
            hints.end (),
            new Variant.int32 (-1)
        });

        this.bus.call.begin (
            "org.freedesktop.Notifications",
            "/org/freedesktop/Notifications",
            "org.freedesktop.Notifications",
            "Notify",
            parameters,
            new VariantType ("(u)"),
            DBusCallFlags.NONE,
            5000,
            null,
            (obj, res) => {
                try {
                    var reply = this.bus.call.end (res);
                    uint32 id = 0;
                    reply.get ("(u)", out id);
                    this.token_by_id.set (id.to_string (), token);
                    this.nid_by_token.set (token, id);
                    Utils.sync_log ("notification id=%u “%s”".printf (id, title));
                } catch (Error e) {
                    warning ("Could not send notification: %s", e.message);
                    fallback (title, body, token, actions, sound);
                }
            }
        );
    }

    private void add_sound_hint (VariantBuilder hints, bool sound) {
        var choice = this.settings.get_string ("notification-sound");
        if (!sound || choice == "none") {
            hints.add ("{sv}", "suppress-sound", new Variant.boolean (true));
            return;
        }

        var path = Utils.notification_sound_filename (choice);
        if (path != null) {
            hints.add ("{sv}", "sound-file", new Variant.string (path));
            return;
        }

        var name = choice.length > 0 ? choice : Utils.NOTIFICATION_SOUND_DEFAULT;
        hints.add ("{sv}", "sound-name", new Variant.string (name));
    }

    private void on_action_invoked (
        DBusConnection connection,
        string? sender_name,
        string object_path,
        string interface_name,
        string signal_name,
        Variant parameters
    ) {
        uint32 id = 0;
        string action = "";
        parameters.get ("(us)", out id, out action);
        var token = this.token_by_id.get (id.to_string ());
        if (token == null)
            return;

        string kind = "open";
        if (action == "archive")
            kind = "archive";
        else if (action == "delete")
            kind = "delete";
        activated (kind, token);
    }

    private void on_notification_closed (
        DBusConnection connection,
        string? sender_name,
        string object_path,
        string interface_name,
        string signal_name,
        Variant parameters
    ) {
        uint32 id = 0;
        uint32 reason = 0;
        parameters.get ("(uu)", out id, out reason);
        var token = this.token_by_id.get (id.to_string ());
        this.token_by_id.remove (id.to_string ());
        if (token != null)
            this.nid_by_token.remove (token);
    }

    private static string notification_key (string token) {
        return "mail-%08x".printf ((uint) token.hash ());
    }
}
