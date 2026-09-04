public enum Mail.InvitationStatus {
    ACCEPTED,
    TENTATIVE,
    DECLINED
}

public enum Mail.InvitationKind {
    REQUEST,
    REPLY,
    CANCEL
}

public class Mail.Invitation : Object {
    public string ics { get; set; default = ""; }
    public string uid { get; set; default = ""; }
    public string summary { get; set; default = ""; }
    public string when_text { get; set; default = ""; }
    public string? location { get; set; }
    public string? organizer { get; set; }
    public InvitationKind kind { get; set; default = InvitationKind.REQUEST; }
    public InvitationStatus response { get; set; default = InvitationStatus.ACCEPTED; }
    public bool has_response { get; set; default = false; }

    public bool can_respond {
        get { return this.kind == InvitationKind.REQUEST; }
    }

    public string fallback_text () {
        switch (this.kind) {
        case InvitationKind.CANCEL:
            return _("This meeting was cancelled.");
        case InvitationKind.REPLY:
            if (!this.has_response)
                return _("This is a meeting response.");
            switch (this.response) {
            case InvitationStatus.ACCEPTED:
                return _("This meeting was accepted.");
            case InvitationStatus.TENTATIVE:
                return _("This meeting was marked as tentative.");
            case InvitationStatus.DECLINED:
                return _("This meeting was declined.");
            }
            return _("This is a meeting response.");
        default:
            return _("This message is a meeting invitation.");
        }
    }
}

public class Mail.CalendarStore : Object {
    private E.SourceRegistry? registry;
    private HashTable<string, ECal.Client> clients;

    public CalendarStore () {
        this.clients = new HashTable<string, ECal.Client> (str_hash, str_equal);
    }

    public void bind_registry (E.SourceRegistry? registry) {
        this.registry = registry;
        this.clients.remove_all ();
    }

    public async void respond (
        Invitation invitation,
        string attendee_email,
        string? mail_source_uid,
        InvitationStatus status,
        Cancellable? cancellable = null
    ) throws Error {
        if (invitation.kind != InvitationKind.REQUEST)
            return;

        var partstat = partstat_from_status (status);
        var client = yield ensure_client (mail_source_uid, cancellable);
        var vcal = parse_vcalendar (invitation.ics);
        if (vcal == null)
            throw new IOError.INVALID_ARGUMENT (_("This invitation could not be read."));

        var reply = make_reply (vcal, attendee_email, partstat);
        yield client.receive_objects (reply, ECal.OperationFlags.NONE, cancellable);

        if (!client.check_save_schedules ())
            return;

        try {
            SList<string>? users = null;
            ICal.Component? modified = null;
            yield client.send_objects (reply, ECal.OperationFlags.NONE, cancellable, out users, out modified);
        } catch (Error send_error) {
            debug ("Calendar send_objects: %s", send_error.message);
        }
    }

    public static Invitation? parse (string? ics) {
        if (ics == null || ics.strip ().length == 0)
            return null;

        var vcal = parse_vcalendar (ics);
        if (vcal == null)
            return null;

        var method = vcal.get_method ();
        var kind = kind_from_method (method);
        if (kind == null)
            return null;

        var vevent = find_vevent (vcal);
        if (vevent == null)
            return null;

        var uid = vevent.get_uid () ?? "";
        if (uid.length == 0)
            return null;

        var summary = vevent.get_summary () ?? _("Meeting");
        var location = vevent.get_location ();
        if (location != null && location.strip ().length == 0)
            location = null;

        string? organizer = null;
        var organizer_prop = vevent.get_first_property (ICal.PropertyKind.ORGANIZER_PROPERTY);
        if (organizer_prop != null)
            organizer = mailto_email (organizer_prop.get_organizer ());

        InvitationStatus response;
        var has_response = status_from_vevent (vevent, out response);
        if (kind == InvitationKind.CANCEL)
            has_response = false;

        return new Invitation () {
            ics = ics,
            uid = uid,
            summary = summary,
            when_text = format_when (vevent),
            location = location,
            organizer = organizer,
            kind = kind,
            response = response,
            has_response = has_response,
        };
    }

    private static InvitationKind? kind_from_method (ICal.PropertyMethod method) {
        switch (method) {
        case ICal.PropertyMethod.REQUEST:
        case ICal.PropertyMethod.PUBLISH:
        case ICal.PropertyMethod.NONE:
            return InvitationKind.REQUEST;
        case ICal.PropertyMethod.REPLY:
        case ICal.PropertyMethod.COUNTER:
            return InvitationKind.REPLY;
        case ICal.PropertyMethod.CANCEL:
            return InvitationKind.CANCEL;
        default:
            return null;
        }
    }

    private static bool status_from_vevent (ICal.Component vevent, out InvitationStatus response) {
        response = InvitationStatus.ACCEPTED;
        var prop = vevent.get_first_property (ICal.PropertyKind.ATTENDEE_PROPERTY);
        while (prop != null) {
            var param = prop.get_first_parameter (ICal.ParameterKind.PARTSTAT_PARAMETER);
            if (param != null) {
                var mapped = status_from_partstat (param.get_partstat ());
                if (mapped != null) {
                    response = mapped;
                    return true;
                }
            }
            prop = vevent.get_next_property (ICal.PropertyKind.ATTENDEE_PROPERTY);
        }
        return false;
    }

    private static InvitationStatus? status_from_partstat (ICal.ParameterPartstat partstat) {
        switch (partstat) {
        case ICal.ParameterPartstat.ACCEPTED:
            return InvitationStatus.ACCEPTED;
        case ICal.ParameterPartstat.TENTATIVE:
            return InvitationStatus.TENTATIVE;
        case ICal.ParameterPartstat.DECLINED:
            return InvitationStatus.DECLINED;
        default:
            return null;
        }
    }

    private async ECal.Client ensure_client (string? mail_source_uid, Cancellable? cancellable) throws Error {
        if (this.registry == null)
            throw new IOError.NOT_FOUND (_("No calendar is available for this account."));

        var source = calendar_source (mail_source_uid);
        if (source == null)
            throw new IOError.NOT_FOUND (_("No calendar is available for this account."));

        var uid = source.get_uid ();
        var existing = this.clients.get (uid);
        if (existing != null)
            return existing;

        var raw = yield ECal.Client.connect (source, ECal.ClientSourceType.EVENTS, 3, cancellable);
        var client = raw as ECal.Client;
        if (client == null)
            throw new IOError.FAILED (_("Could not open the calendar."));

        this.clients.set (uid, client);
        return client;
    }

    private E.Source? calendar_source (string? mail_source_uid) {
        if (this.registry == null)
            return null;

        string? parent = null;
        if (mail_source_uid != null) {
            var mail = this.registry.ref_source (mail_source_uid);
            if (mail != null)
                parent = mail.get_parent ();
        }

        foreach (var source in this.registry.list_enabled (E.SOURCE_EXTENSION_CALENDAR)) {
            if (!source.get_writable ())
                continue;
            if (parent != null && source.get_parent () == parent)
                return source;
        }

        var fallback = this.registry.ref_default_calendar ();
        if (fallback != null && fallback.get_enabled () && fallback.get_writable ())
            return fallback;
        return null;
    }

    private static ICal.Component make_reply (
        ICal.Component vcal,
        string attendee_email,
        ICal.ParameterPartstat partstat
    ) {
        var reply = vcal.clone ();
        reply.set_method (ICal.PropertyMethod.REPLY);
        var vevent = find_vevent (reply);
        if (vevent == null)
            return reply;

        vevent.set_dtstamp (new ICal.Time.from_timet_with_zone (
            (time_t) new DateTime.now_utc ().to_unix (),
            false,
            ICal.Timezone.get_utc_timezone ()
        ));
        apply_partstat (vevent, attendee_email, partstat);
        return reply;
    }

    private static void apply_partstat (
        ICal.Component vevent,
        string attendee_email,
        ICal.ParameterPartstat partstat
    ) {
        var me = attendee_email.down ();
        var found = false;
        var prop = vevent.get_first_property (ICal.PropertyKind.ATTENDEE_PROPERTY);
        while (prop != null) {
            var next = vevent.get_next_property (ICal.PropertyKind.ATTENDEE_PROPERTY);
            var email = mailto_email (prop.get_attendee ());
            if (email == me) {
                found = true;
                prop.remove_parameter_by_kind (ICal.ParameterKind.PARTSTAT_PARAMETER);
                prop.remove_parameter_by_kind (ICal.ParameterKind.RSVP_PARAMETER);
                prop.add_parameter (new ICal.Parameter.partstat (partstat));
                prop.add_parameter (new ICal.Parameter.rsvp (ICal.ParameterRsvp.TRUE));
            }
            prop = next;
        }

        if (found)
            return;

        var attendee = new ICal.Property.attendee ("mailto:" + me);
        attendee.add_parameter (new ICal.Parameter.partstat (partstat));
        attendee.add_parameter (new ICal.Parameter.rsvp (ICal.ParameterRsvp.TRUE));
        vevent.add_property (attendee);
    }

    private static ICal.Component? parse_vcalendar (string ics) {
        var parsed = ECal.util_parse_ics_string (ics);
        if (parsed == null)
            parsed = new ICal.Component.from_string (ics);
        if (parsed == null || !parsed.is_valid ())
            return null;
        if (parsed.isa () == ICal.ComponentKind.VCALENDAR_COMPONENT)
            return parsed;
        if (parsed.isa () == ICal.ComponentKind.VEVENT_COMPONENT) {
            var wrap = new ICal.Component (ICal.ComponentKind.VCALENDAR_COMPONENT);
            wrap.set_method (ICal.PropertyMethod.REQUEST);
            wrap.add_component (parsed);
            return wrap;
        }
        return null;
    }

    private static ICal.Component? find_vevent (ICal.Component root) {
        if (root.isa () == ICal.ComponentKind.VEVENT_COMPONENT)
            return root;
        return root.get_first_component (ICal.ComponentKind.VEVENT_COMPONENT);
    }

    private static string format_when (ICal.Component vevent) {
        var start = vevent.get_dtstart ();
        var end = vevent.get_dtend ();
        if (start == null || start.is_null_time () || !start.is_valid_time ())
            return "";

        var start_dt = new DateTime.from_unix_local ((int64) start.as_timet ());
        if (start.is_date ())
            return start_dt.format ("%a %-d %b");

        var text = start_dt.format ("%a %-d %b, %H:%M");
        if (end != null && !end.is_null_time () && end.is_valid_time ()) {
            var end_dt = new DateTime.from_unix_local ((int64) end.as_timet ());
            if (end_dt.get_day_of_year () == start_dt.get_day_of_year ()
                && end_dt.get_year () == start_dt.get_year ())
                text += "–%s".printf (end_dt.format ("%H:%M"));
            else
                text += " – %s".printf (end_dt.format ("%a %-d %b, %H:%M"));
        }
        return text;
    }

    private static string mailto_email (string? raw) {
        if (raw == null)
            return "";
        var value = raw.strip ();
        if (value.down ().has_prefix ("mailto:"))
            value = value.substring (7);
        return Utils.sanitize_recipient_text (value).down ();
    }

    private static ICal.ParameterPartstat partstat_from_status (InvitationStatus status) {
        switch (status) {
        case InvitationStatus.ACCEPTED:
            return ICal.ParameterPartstat.ACCEPTED;
        case InvitationStatus.TENTATIVE:
            return ICal.ParameterPartstat.TENTATIVE;
        case InvitationStatus.DECLINED:
            return ICal.ParameterPartstat.DECLINED;
        }
        return ICal.ParameterPartstat.NEEDSACTION;
    }
}
