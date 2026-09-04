public class Mail.InvitationBar : Gtk.Box {
    public signal void respond (InvitationStatus status);

    private Gtk.Label heading;
    private Gtk.Label summary;
    private Gtk.Label details;
    private Gtk.Box buttons;
    private Gtk.Label status_label;
    private Gtk.Spinner spinner;
    private Gtk.Button accept_button;
    private Gtk.Button tentative_button;
    private Gtk.Button decline_button;

    public InvitationBar () {
        Object (orientation: Gtk.Orientation.VERTICAL, spacing: 8);
        add_css_class ("invitation-bar");
        visible = false;

        this.heading = new Gtk.Label (_("Meeting Invitation")) {
            xalign = 0,
            use_markup = false,
        };
        this.heading.add_css_class ("caption-heading");

        this.summary = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            use_markup = false,
        };
        this.summary.add_css_class ("heading");

        this.details = new Gtk.Label ("") {
            xalign = 0,
            wrap = true,
            use_markup = false,
        };
        this.details.add_css_class ("dim-label");
        this.details.add_css_class ("caption");

        this.status_label = new Gtk.Label (_("This event is waiting for your reply.")) {
            xalign = 0,
            wrap = true,
            use_markup = false,
        };
        this.status_label.add_css_class ("caption");
        this.status_label.add_css_class ("dim-label");

        this.accept_button = new Gtk.Button.with_label (_("Accept"));
        this.accept_button.add_css_class ("suggested-action");
        this.accept_button.add_css_class ("pill");
        this.accept_button.clicked.connect (() => respond (InvitationStatus.ACCEPTED));

        this.tentative_button = new Gtk.Button.with_label (_("Tentative"));
        this.tentative_button.add_css_class ("pill");
        this.tentative_button.clicked.connect (() => respond (InvitationStatus.TENTATIVE));

        this.decline_button = new Gtk.Button.with_label (_("Decline"));
        this.decline_button.add_css_class ("destructive-action");
        this.decline_button.add_css_class ("pill");
        this.decline_button.clicked.connect (() => respond (InvitationStatus.DECLINED));

        this.spinner = new Gtk.Spinner () {
            width_request = 16,
            height_request = 16,
            visible = false,
        };

        this.buttons = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
        this.buttons.append (this.accept_button);
        this.buttons.append (this.tentative_button);
        this.buttons.append (this.decline_button);
        this.buttons.append (this.spinner);

        append (this.heading);
        append (this.summary);
        append (this.details);
        append (this.status_label);
        append (this.buttons);
    }

    public void bind (Invitation? invitation) {
        if (invitation == null) {
            visible = false;
            this.buttons.visible = true;
            set_busy (false);
            return;
        }

        this.summary.label = invitation.summary;
        if (invitation.when_text.length > 0 && invitation.location != null && invitation.location.length > 0)
            this.details.label = "%s · %s".printf (invitation.when_text, invitation.location);
        else if (invitation.when_text.length > 0)
            this.details.label = invitation.when_text;
        else
            this.details.label = invitation.location ?? "";
        this.details.visible = this.details.label.length > 0;
        this.heading.label = heading_for (invitation);
        this.buttons.visible = invitation.can_respond;
        if (invitation.kind == InvitationKind.CANCEL)
            this.status_label.label = _("This meeting was cancelled.");
        else if (invitation.has_response)
            this.status_label.label = response_label (invitation.response, false);
        else
            this.status_label.label = _("This event is waiting for your reply.");
        set_busy (false);
        visible = true;
    }

    public void set_busy (bool busy) {
        this.accept_button.sensitive = !busy;
        this.tentative_button.sensitive = !busy;
        this.decline_button.sensitive = !busy;
        this.spinner.visible = busy;
        if (busy)
            this.spinner.start ();
        else
            this.spinner.stop ();
    }

    public void show_status (InvitationStatus status) {
        this.status_label.label = response_label (status, true);
        this.buttons.visible = false;
        set_busy (false);
    }

    private static string heading_for (Invitation invitation) {
        switch (invitation.kind) {
        case InvitationKind.CANCEL:
            return _("Meeting Cancelled");
        case InvitationKind.REPLY:
            return _("Meeting Response");
        default:
            return _("Meeting Invitation");
        }
    }

    private static string response_label (InvitationStatus status, bool notify_organizer) {
        switch (status) {
        case InvitationStatus.ACCEPTED:
            return notify_organizer
                ? _("Accepted. The organizer will be notified.")
                : _("This meeting was accepted.");
        case InvitationStatus.TENTATIVE:
            return notify_organizer
                ? _("Marked as tentative. The organizer will be notified.")
                : _("This meeting was marked as tentative.");
        case InvitationStatus.DECLINED:
            return notify_organizer
                ? _("Declined. The organizer will be notified.")
                : _("This meeting was declined.");
        }
        return _("This is a meeting response.");
    }
}
