public class Mail.MessageWindow : Adw.ApplicationWindow {
    public signal void folder_changed ();
    public signal void flags_changed ();

    private MailSession session;
    private AccountStore store;
    private Account account;
    private Folder folder;
    private GenericArray<Folder> folders;
    private Message message;
    private MessageContent mail;
    private Adw.ToastOverlay toast_overlay;
    private MessageReader reader;
    private MessageActionBar actions;

    private const ActionEntry[] WINDOW_ACTIONS = {
        { "reply", on_reply },
        { "reply-all", on_reply_all },
        { "forward", on_forward },
        { "send-again", on_send_again },
        { "move", on_move_clicked },
        { "archive", on_archive_clicked },
        { "delete", on_delete_clicked },
        { "mark-unread", on_mark_unread },
        { "mark-read", on_mark_read },
        { "bookmark", on_bookmark_clicked },
        { "mark-important", on_mark_important },
        { "print", on_print },
        { "zoom-in", on_zoom_in },
        { "zoom-out", on_zoom_out },
        { "zoom-reset", on_zoom_reset },
    };

    public MessageWindow (
        Gtk.Application app,
        MailSession session,
        AccountStore store,
        Account account,
        Folder folder,
        GenericArray<Folder> folders,
        Message message,
        MessageContent mail
    ) {
        var settings = new Settings (Config.APP_ID);
        Object (
            application: app,
            title: mail.subject,
            default_width: settings.get_int ("compose-width").clamp (520, 4000),
            default_height: settings.get_int ("compose-height").clamp (420, 4000)
        );

        this.session = session;
        this.store = store;
        this.account = account;
        this.folder = folder;
        this.folders = folders;
        this.message = message;
        this.mail = mail;
        resizable = true;

        if (Config.PROFILE == "development")
            add_css_class ("devel");

        add_action_entries (WINDOW_ACTIONS, this);
        Utils.add_mail_letter_shortcuts (this);

        var header = new Adw.HeaderBar ();
        this.actions = new MessageActionBar ();
        this.actions.add_css_class ("in-reader");
        this.actions.valign = Gtk.Align.CENTER;
        header.pack_start (this.actions);
        sync_actions ();

        this.reader = new MessageReader ();
        this.reader.set_show_header_actions (false);
        this.reader.set_mailbox (account, session.get_identity (account));
        this.reader.set_contacts ((app as Application)?.contacts);
        this.reader.show_content (mail, message.outgoing);
        this.reader.invitation_respond.connect ((invitation, status) => {
            respond_invitation.begin (this.reader, invitation, status);
        });

        var toolbar = new Adw.ToolbarView () {
            content = this.reader,
        };
        toolbar.add_top_bar (header);

        this.toast_overlay = new Adw.ToastOverlay () {
            child = toolbar,
        };
        this.content = this.toast_overlay;
    }

    private void sync_actions () {
        var outgoing = this.message.outgoing;
        var draft = this.folder.kind == FolderKind.DRAFTS
            || (this.message.uid != null && this.message.uid.has_prefix ("local-draft-"));
        var archived = this.folder.is_archive_mailbox;
        var can_important = this.account.kind == AccountKind.GOOGLE
            && !outgoing
            && !this.message.is_placeholder
            && find_kind (FolderKind.IMPORTANT) != null;
        set_action_enabled ("reply", !outgoing && !draft);
        set_action_enabled ("reply-all", !draft);
        set_action_enabled ("forward", !draft);
        set_action_enabled ("send-again", (outgoing && !this.message.is_placeholder) || draft);
        set_action_enabled ("move", true);
        set_action_enabled ("archive", !outgoing && !archived);
        set_action_enabled ("delete", true);
        set_action_enabled ("mark-unread", !outgoing && this.message.seen);
        set_action_enabled ("mark-read", !outgoing && !this.message.seen);
        set_action_enabled ("bookmark", !this.message.is_placeholder);
        set_action_enabled ("mark-important", can_important);
        set_action_enabled ("print", true);
        this.actions.set_seen (this.message.seen, !outgoing);
        this.actions.set_outgoing (outgoing, draft);
        this.actions.set_bookmarked (this.message.flagged);
        this.actions.set_important (can_important, this.message.important);
    }

    private void set_action_enabled (string name, bool enabled) {
        var action = lookup_action (name) as SimpleAction;
        action?.set_enabled (enabled);
    }

    private void on_move_clicked () {
        choose_and_move.begin ();
    }

    private void on_archive_clicked () {
        archive.begin ();
    }

    private void on_delete_clicked () {
        trash_message.begin ();
    }

    private void on_bookmark_clicked () {
        toggle_bookmark.begin ();
    }

    private void on_mark_read () {
        set_seen.begin (true);
    }

    private void on_mark_unread () {
        set_seen.begin (false);
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

    private void on_mark_important () {
        toggle_important.begin ();
    }

    private async void toggle_bookmark () {
        if (this.message.is_placeholder)
            return;

        var flagged = !this.message.flagged;
        var uids = new GenericArray<string> ();
        uids.add (this.message.uid);
        try {
            yield this.session.set_uids_flagged (this.account, this.folder, uids, flagged);
            this.message.flagged = flagged;
            this.actions.set_bookmarked (flagged);
            flags_changed ();
        } catch (Error e) {
            toast (e.message);
        }
    }

    private async void set_seen (bool seen) {
        if (this.message.outgoing)
            return;

        var uids = new GenericArray<string> ();
        uids.add (this.message.uid);
        try {
            yield this.session.set_uids_seen (this.account, this.folder, uids, seen);
            this.message.seen = seen;
            sync_actions ();
            flags_changed ();
        } catch (Error e) {
            toast (e.message);
        }
    }

    private async void toggle_important () {
        if (this.message.is_placeholder || this.message.outgoing || this.account.kind != AccountKind.GOOGLE)
            return;

        var destination = find_kind (FolderKind.IMPORTANT);
        if (destination == null) {
            toast (_("No Important folder was found for this account."));
            return;
        }

        var important = !this.message.important;
        try {
            if (important) {
                if (this.folder.kind != FolderKind.IMPORTANT)
                    yield this.session.copy_message (this.account, this.folder, this.message.uid, destination);
            } else {
                var source = this.folder.kind == FolderKind.IMPORTANT ? this.folder : destination;
                var uids = new GenericArray<string> ();
                uids.add (this.message.uid);
                yield this.session.delete_uids (this.account, source, uids, null);
                if (this.folder.kind == FolderKind.IMPORTANT) {
                    folder_changed ();
                    close ();
                    return;
                }
            }
            this.message.important = important;
            sync_actions ();
            flags_changed ();
        } catch (Error e) {
            toast (e.message);
        }
    }

    private void on_reply () {
        if (this.message.outgoing)
            return;

        present_compose (
            Utils.format_mailbox (
                Utils.display_address (this.mail.from),
                this.mail.from_email ?? Utils.email_from_header (this.mail.from)
            ),
            null,
            Utils.reply_subject (this.mail.subject),
            false
        );
    }

    private void on_reply_all () {
        var identity = this.session.get_identity (this.account);
        var self = identity != null ? identity.address : this.account.email;
        string to;
        string? cc;
        Utils.reply_all_addresses (this.mail, self, out to, out cc);
        present_compose (
            to,
            cc,
            Utils.reply_subject (this.mail.subject),
            false
        );
    }

    private void on_forward () {
        present_compose (
            null,
            null,
            Utils.forward_subject (this.mail.subject),
            true
        );
    }

    private void on_send_again () {
        if (this.folder.kind == FolderKind.DRAFTS
            || (this.message.uid != null && this.message.uid.has_prefix ("local-draft-"))) {
            present_compose (
                null,
                null,
                this.mail.subject == _("(No subject)") ? "" : this.mail.subject,
                false,
                null,
                false,
                true
            );
            return;
        }
        if (!this.message.outgoing || this.message.is_placeholder)
            return;

        string to;
        string? cc;
        string? bcc;
        Utils.resend_addresses (this.mail, out to, out cc, out bcc);
        var subject = this.mail.subject;
        if (subject == _("(No subject)"))
            subject = "";
        present_compose (to, cc, subject, false, bcc, true);
    }

    private void present_compose (string? to, string? cc, string subject, bool forward, string? bcc = null, bool resend = false, bool edit_draft = false) {
        var app = get_application ();
        if (app == null)
            return;

        string? draft_to = to;
        string? draft_cc = cc;
        string? draft_bcc = bcc;
        if (edit_draft) {
            Utils.resend_addresses (this.mail, out draft_to, out draft_cc, out draft_bcc);
        }

        var compose = new ComposeWindow (
            app,
            this.session,
            this.store,
            this.account,
            draft_to,
            draft_cc,
            subject,
            this.mail,
            forward,
            draft_bcc,
            resend,
            edit_draft ? this.message : null,
            edit_draft ? this.folder : null
        );
        compose.present ();
    }

    private async void respond_invitation (
        MessageReader reader,
        Invitation invitation,
        InvitationStatus status
    ) {
        var app = get_application () as Application;
        if (app == null)
            return;

        var identity = this.session.get_identity (this.account);
        var email = identity != null ? identity.address : this.account.email;
        if (email == null || email.length == 0) {
            toast (_("This account has no sending identity."));
            return;
        }

        reader.set_invitation_busy (true);
        try {
            yield app.calendars.respond (invitation, email, this.account.source_uid, status, null);
            reader.show_invitation_status (status);
            if (status != InvitationStatus.TENTATIVE)
                trash_message.begin ();
        } catch (Error e) {
            reader.set_invitation_busy (false);
            toast (e.message);
        }
    }

    private async void archive () {
        if (this.message.outgoing || this.folder.is_archive_mailbox)
            return;

        var archive = find_kind (FolderKind.ARCHIVE) ?? find_kind (FolderKind.ALL);
        if (archive == null) {
            toast (_("No Archive folder was found for this account."));
            return;
        }

        if (this.folder.full_name == archive.full_name)
            return;

        try {
            yield this.session.move_message (this.account, this.folder, this.message.uid, archive);
            folder_changed ();
            close ();
        } catch (Error e) {
            toast (e.message);
        }
    }

    private async void trash_message () {
        try {
            yield this.session.delete_message (this.account, this.folder, this.message.uid, find_kind (FolderKind.TRASH));
            folder_changed ();
            close ();
        } catch (Error e) {
            toast (e.message);
        }
    }

    private async void choose_and_move () {
        var destination = yield Window.pick_folder (this, this.folders, this.folder);
        if (destination == null)
            return;

        try {
            yield this.session.move_message (this.account, this.folder, this.message.uid, destination);
            folder_changed ();
            close ();
        } catch (Error e) {
            toast (e.message);
        }
    }

    private Folder? find_kind (FolderKind kind) {
        for (uint i = 0; i < this.folders.length; i++) {
            if (this.folders[i].kind == kind)
                return this.folders[i];
        }
        return null;
    }

    private void toast (string message) {
        this.toast_overlay.add_toast (new Adw.Toast (message) {
            timeout = 4,
        });
    }
}
