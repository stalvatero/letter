/* Read-only window for a local .eml / message/rfc822 file.
 * No reply, forward, archive, or account mutations — viewing only. */
public class Mail.EmlViewerWindow : Adw.ApplicationWindow {
    private MessageReader reader;
    private MessageContent mail;
    private string? source_name;

    private const ActionEntry[] WINDOW_ACTIONS = {
        { "print", on_print },
        { "zoom-in", on_zoom_in },
        { "zoom-out", on_zoom_out },
        { "zoom-reset", on_zoom_reset },
    };

    public EmlViewerWindow (Gtk.Application app, MessageContent mail, string? source_name) {
        var settings = new Settings (Config.APP_ID);
        Object (
            application: app,
            title: mail.subject ?? _("Message"),
            default_width: settings.get_int ("compose-width").clamp (520, 4000),
            default_height: settings.get_int ("compose-height").clamp (420, 4000)
        );
        this.mail = mail;
        this.source_name = source_name;
        resizable = true;

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        add_action_entries (WINDOW_ACTIONS, this);
        Utils.add_mail_letter_shortcuts (this);

        var header = new Adw.HeaderBar ();
        if (source_name != null && source_name.length > 0) {
            header.title_widget = new Adw.WindowTitle (mail.subject ?? _("Message"), source_name);
        }

        var print_btn = new Gtk.Button.from_icon_name (Utils.icon ("document-print-symbolic")) {
            tooltip_text = _("Print"),
            action_name = "win.print",
        };
        print_btn.add_css_class ("flat");
        header.pack_end (print_btn);

        this.reader = new MessageReader ();
        this.reader.set_show_header_actions (false);
        var app_obj = app as Application;
        if (app_obj != null)
            this.reader.set_contacts (app_obj.contacts);
        this.reader.show_content (mail, false);
        this.reader.set_show_invitation_actions (false);

        var toolbar = new Adw.ToolbarView () {
            content = this.reader,
        };
        toolbar.add_top_bar (header);
        this.content = toolbar;
    }

    public static async MessageContent load_file (File file) throws Error {
        var bytes = yield file.load_bytes_async (null, null);
        if (bytes.get_size () == 0)
            throw new IOError.INVALID_DATA (_("This file is empty."));

        var input = new MemoryInputStream.from_bytes (bytes);
        var mime = new Camel.MimeMessage ();
        if (!mime.construct_from_input_stream_sync (input, null))
            throw new IOError.INVALID_DATA (_("Could not read this message file."));

        var path = file.get_path () ?? file.get_uri ();
        var uid = "eml-file-%08x".printf ((uint) path.hash ());
        return MessageContent.from_mime (uid, mime);
    }

    public static bool looks_like_eml (File file) {
        var name = file.get_basename () ?? "";
        if (name.down ().has_suffix (".eml"))
            return true;
        try {
            var info = file.query_info (
                FileAttribute.STANDARD_CONTENT_TYPE,
                FileQueryInfoFlags.NONE,
                null
            );
            var type = info.get_content_type () ?? "";
            return type == "message/rfc822"
                || type == "application/eml"
                || type.has_prefix ("message/");
        } catch (Error e) {
            return false;
        }
    }

    private void on_print () {
        this.reader.print (this);
    }

    private void on_zoom_in () {
        this.reader.zoom_in ();
    }

    private void on_zoom_out () {
        this.reader.zoom_out ();
    }

    private void on_zoom_reset () {
        this.reader.zoom_reset ();
    }
}
