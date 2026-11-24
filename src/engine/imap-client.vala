/**
 * Bare IMAP over GIO TLS — no Camel, no EDS.
 * Shared by letter-imap-spike and ImapMailBackend (Phase 2 engine).
 */
public errordomain LetterImap.Error {
    PROTOCOL,
    AUTH,
    IO
}

public class LetterImap.Client : Object {
    private SocketConnection? connection;
    private DataInputStream? input;
    private DataOutputStream? output;
    private uint next_tag = 1;
    private string? selected;

    public string? greeting { get; private set; }

    public void connect_tls (string host, uint16 port = 993, Cancellable? cancellable = null) throws GLib.Error {
        var client = new SocketClient () {
            tls = true,
            tls_validation_flags = TlsCertificateFlags.VALIDATE_ALL,
        };

        this.connection = client.connect_to_host (host, port, cancellable);
        this.input = new DataInputStream (this.connection.get_input_stream ());
        this.input.set_newline_type (DataStreamNewlineType.CR_LF);
        this.output = new DataOutputStream (this.connection.get_output_stream ());

        this.greeting = read_line (cancellable);
        if (this.greeting == null || !this.greeting.has_prefix ("* OK")) {
            throw new LetterImap.Error.PROTOCOL (
                "Unexpected IMAP greeting: %s".printf (this.greeting ?? "(null)")
            );
        }
    }

    public void login (string user, string password, Cancellable? cancellable = null) throws GLib.Error {
        var resp = command (
            "LOGIN %s %s".printf (quote (user), quote (password)),
            cancellable
        );
        if (!resp.ok) {
            throw new LetterImap.Error.AUTH ("LOGIN failed: %s".printf (resp.text));
        }
    }

    /** RFC 7628 / Google XOAUTH2 — SASL initial response on the AUTHENTICATE line. */
    public void authenticate_xoauth2 (
        string user,
        string access_token,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var raw = "user=%s\u0001auth=Bearer %s\u0001\u0001".printf (user, access_token);
        var b64 = Base64.encode (raw.data);
        var tag = "A%u".printf (this.next_tag++);
        write_line ("%s AUTHENTICATE XOAUTH2 %s".printf (tag, b64), cancellable);
        while (true) {
            var line = read_line (cancellable);
            if (line == null) {
                throw new LetterImap.Error.IO ("Connection closed during AUTHENTICATE XOAUTH2");
            }
            if (line.has_prefix ("+")) {
                /* Failure challenge — send empty response then read tagged NO. */
                write_line ("", cancellable);
                continue;
            }
            if (line.has_prefix (tag + " ")) {
                var status = line.substring (tag.length + 1);
                if (status.has_prefix ("OK"))
                    return;
                throw new LetterImap.Error.AUTH ("XOAUTH2 failed: %s".printf (status));
            }
        }
    }

    public GenericArray<string> list_mailboxes (Cancellable? cancellable = null) throws GLib.Error {
        var mailboxes = new GenericArray<string> ();
        var raw_list_lines = new GenericArray<string> ();
        var resp = command_collect ("LIST \"\" \"*\"", cancellable, (line) => {
            if (!line.has_prefix ("* LIST"))
                return;
            raw_list_lines.add (line);
            var name = extract_list_mailbox (line);
            if (name != null && name.length > 0)
                mailboxes.add (name);
        });
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("LIST failed: %s".printf (resp.text));
        }
        if (mailboxes.length == 0 && raw_list_lines.length > 0) {
            stderr.printf (
                "LIST: received %u untagged line(s) but parsed 0 names; sample:\n  %s\n",
                raw_list_lines.length,
                raw_list_lines[0]
            );
        }
        return mailboxes;
    }

    public class MailboxStatus : Object {
        public uint messages { get; set; }
        public uint unseen { get; set; }
    }

    /** IMAP STATUS for sidebar badges — does not SELECT the mailbox. */
    public MailboxStatus status_mailbox (string mailbox, Cancellable? cancellable = null) throws GLib.Error {
        var result = new MailboxStatus ();
        var resp = command_collect (
            "STATUS %s (MESSAGES UNSEEN)".printf (quote (mailbox)),
            cancellable,
            (line) => {
                if (!line.has_prefix ("* STATUS "))
                    return;
                parse_status_line (line, result);
            }
        );
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("STATUS failed: %s".printf (resp.text));
        }
        return result;
    }

    public uint select (string mailbox, Cancellable? cancellable = null) throws GLib.Error {
        uint exists = 0;
        var resp = command_collect (
            "SELECT %s".printf (quote (mailbox)),
            cancellable,
            (line) => {
                if (!line.has_prefix ("* "))
                    return;
                var parts = line.substring (2).split (" ", 2);
                if (parts.length >= 2 && parts[1].has_prefix ("EXISTS"))
                    uint.try_parse (parts[0], out exists);
            }
        );
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("SELECT failed: %s".printf (resp.text));
        }
        this.selected = mailbox;
        return exists;
    }

    public enum IdleWake {
        EXISTS,
        EXPUNGE,
        FLAGS,
        TIMEOUT,
        CANCELLED
    }

    /** One untagged EXISTS/EXPUNGE/FETCH from IDLE (or DONE drain). */
    public class IdleEvent {
        public IdleWake wake = IdleWake.TIMEOUT;
        public uint exists_hint;
        public uint expunge_seq; /* 1-based sequence removed */
        public uint fetch_seq;
        public string? fetch_uid;
        public bool flags_present;
        public bool seen;
        public bool flagged;
    }

    /**
     * One IDLE cycle: wait for activity, then burst-drain sibling untagged
     * lines (Gmail often sends two FETCH/EXPUNGE back-to-back), then DONE
     * and keep parsing until the tagged OK.
     */
    public class IdleBatch {
        public IdleWake wake = IdleWake.TIMEOUT;
        public GenericArray<IdleEvent> events = new GenericArray<IdleEvent> ();
        public uint exists_hint;
        public bool has_exists;
    }

    /* GSocket timeout is whole seconds; 1s is enough to catch a multi-untagged burst. */
    public const uint IDLE_BURST_SECONDS = 1;

    /**
     * RFC 2177 IDLE on the selected mailbox. Blocks until activity,
     * @timeout_seconds (renew), or @cancellable. Always ends with DONE.
     */
    public IdleBatch idle (
        uint timeout_seconds,
        Cancellable? cancellable
    ) throws GLib.Error {
        var batch = new IdleBatch ();
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected for IDLE");
        }
        if (this.connection == null || this.input == null || this.output == null) {
            throw new LetterImap.Error.IO ("Not connected");
        }

        var tag = "A%u".printf (this.next_tag++);
        write_line ("%s IDLE".printf (tag), cancellable);

        while (true) {
            var line = read_line (cancellable);
            if (line == null) {
                throw new LetterImap.Error.IO ("Connection closed waiting for IDLE +");
            }
            if (line.has_prefix ("+"))
                break;
            if (line.has_prefix (tag + " ")) {
                throw new LetterImap.Error.PROTOCOL ("IDLE rejected: %s".printf (line));
            }
        }

        var sock = this.connection.get_socket ();
        uint prev_timeout = 0;
        try {
            prev_timeout = sock.get_timeout ();
        } catch (GLib.Error e) {
            prev_timeout = 0;
        }
        if (timeout_seconds > 0)
            sock.set_timeout (timeout_seconds);

        var got_activity = false;
        try {
            while (true) {
                if (cancellable != null && cancellable.is_cancelled ()) {
                    batch.wake = IdleWake.CANCELLED;
                    break;
                }
                string? line;
                try {
                    line = read_line (cancellable);
                } catch (IOError e) {
                    if (e is IOError.TIMED_OUT || e.code == IOError.TIMED_OUT
                        || (e.message != null && e.message.down ().contains ("timed out"))) {
                        if (!got_activity)
                            batch.wake = IdleWake.TIMEOUT;
                        break; /* renew, or end of burst */
                    }
                    if (e is IOError.CANCELLED) {
                        batch.wake = IdleWake.CANCELLED;
                        break;
                    }
                    throw e;
                }
                if (line == null) {
                    throw new LetterImap.Error.IO ("Connection closed during IDLE");
                }
                if (!absorb_idle_untagged (line, batch))
                    continue;
                if (!got_activity) {
                    got_activity = true;
                    batch.wake = IdleWake.EXISTS; /* any activity; events carry the detail */
                    sock.set_timeout (IDLE_BURST_SECONDS);
                }
            }
        } finally {
            try {
                sock.set_timeout (prev_timeout);
            } catch (GLib.Error e) {
            }
        }

        try {
            write_line ("DONE", null);
        } catch (GLib.Error e) {
            return batch;
        }
        while (true) {
            string? line;
            try {
                line = read_line (null);
            } catch (GLib.Error e) {
                break;
            }
            if (line == null)
                break;
            if (line.has_prefix ("* ")) {
                absorb_idle_untagged (line, batch);
                continue;
            }
            if (line.has_prefix (tag + " "))
                break;
        }
        return batch;
    }

    /** Parse one `* …` IDLE/DONE line into @batch. Returns true if it was interesting. */
    private static bool absorb_idle_untagged (string line, IdleBatch batch) {
        if (!line.has_prefix ("* "))
            return false;
        var parts = line.substring (2).split (" ", 2);
        if (parts.length < 2)
            return false;
        if (parts[1].has_prefix ("EXISTS")) {
            uint hint = 0;
            uint.try_parse (parts[0], out hint);
            batch.exists_hint = hint;
            batch.has_exists = true;
            var ev = new IdleEvent ();
            ev.wake = IdleWake.EXISTS;
            ev.exists_hint = hint;
            batch.events.add (ev);
            return true;
        }
        if (parts[1].has_prefix ("EXPUNGE")) {
            var ev = new IdleEvent ();
            ev.wake = IdleWake.EXPUNGE;
            uint.try_parse (parts[0], out ev.expunge_seq);
            batch.events.add (ev);
            return true;
        }
        if (parts[1].contains ("FETCH")) {
            var ev = new IdleEvent ();
            ev.wake = IdleWake.FLAGS;
            uint.try_parse (parts[0], out ev.fetch_seq);
            ev.fetch_uid = extract_atom_after (line, "UID ");
            parse_idle_fetch_flags (line, ev);
            batch.events.add (ev);
            return true;
        }
        return false;
    }

    private static void parse_idle_fetch_flags (string line, IdleEvent ev) {
        var idx = line.index_of ("FLAGS (");
        if (idx < 0)
            return;
        var start = idx + 7;
        var end = line.index_of_char (')', start);
        if (end < 0)
            return;
        var flags = line.substring (start, end - start).down ();
        ev.flags_present = true;
        ev.seen = flags.contains ("\\seen");
        ev.flagged = flags.contains ("\\flagged");
    }

    /**
     * FETCH @from_seq:@to_seq (UID). Result[i] is the UID for sequence
     * from_seq+i ("" if the server omitted that seq).
     */
    public GenericArray<string> fetch_uid_range (
        uint from_seq,
        uint to_seq,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        if (from_seq < 1 || to_seq < from_seq) {
            throw new LetterImap.Error.PROTOCOL ("Invalid sequence range");
        }
        uint n = to_seq - from_seq + 1;
        var uids = new GenericArray<string> ();
        for (uint i = 0; i < n; i++)
            uids.add ("");

        var cmd = "FETCH %u:%u (UID)".printf (from_seq, to_seq);
        var resp = command_collect (cmd, cancellable, (line) => {
            if (!(line.has_prefix ("* ") && line.contains (" FETCH ")))
                return;
            var rest = line.substring (2);
            var sp = rest.index_of_char (' ');
            if (sp <= 0)
                return;
            uint seq = 0;
            if (!uint.try_parse (rest.substring (0, sp), out seq))
                return;
            if (seq < from_seq || seq > to_seq)
                return;
            var uid = extract_atom_after (line, "UID ");
            if (uid != null && uid.length > 0)
                uids[(int) (seq - from_seq)] = uid;
        });
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("FETCH UID map failed: %s".printf (resp.text));
        }
        return uids;
    }

    public class Header : Object {
        public uint seq { get; set; }
        public string? uid { get; set; }
        public string? from { get; set; }
        public string? subject { get; set; }
        public string? date { get; set; }
        /* IMAP INTERNALDATE — fallback when Date is asctime / missing. */
        public string? internal_date { get; set; }
        public string? to { get; set; }
        public string? message_id { get; set; }
        public string? in_reply_to { get; set; }
        public string? references { get; set; }
        public string? content_type { get; set; }
        public bool seen { get; set; }
        public bool flagged { get; set; }
        /* Envelope heuristic (multipart/mixed, filename, …) — not BODYSTRUCTURE. */
        public bool has_attachment { get; set; }
    }

    public GenericArray<Header> fetch_headers (
        uint from_seq,
        uint to_seq,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        if (from_seq < 1 || to_seq < from_seq) {
            throw new LetterImap.Error.PROTOCOL ("Invalid sequence range");
        }

        var headers = new GenericArray<Header> ();
        var cmd = ("FETCH %u:%u (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS " +
            "(FROM SUBJECT DATE TO MESSAGE-ID IN-REPLY-TO REFERENCES " +
            "CONTENT-TYPE CONTENT-DISPOSITION)])").printf (
            from_seq, to_seq
        );

        var resp = command_collect (cmd, cancellable, (line) => {
            if (!(line.has_prefix ("* ") && line.contains (" FETCH ")))
                return;

            var header = parse_fetch_header_line (line, cancellable);
            if (header != null)
                headers.add (header);
        });

        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("FETCH headers failed: %s".printf (resp.text));
        }
        return headers;
    }

    public string fetch_body (uint seq, Cancellable? cancellable = null) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }

        string? body = null;
        var resp = command_collect (
            "FETCH %u BODY.PEEK[]".printf (seq),
            cancellable,
            (line) => {
                if (!(line.has_prefix ("* ") && line.contains (" FETCH ")))
                    return;
                size_t lit = literal_size_at_end (line);
                if (lit == 0)
                    return;
                try {
                    body = read_exact (lit, cancellable);
                    read_line (cancellable);
                } catch (GLib.Error e) {
                    warning ("Body literal read failed: %s", e.message);
                }
            }
        );

        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("FETCH body failed: %s".printf (resp.text));
        }
        if (body == null) {
            throw new LetterImap.Error.PROTOCOL ("FETCH body returned no literal");
        }
        return body;
    }

    /**
     * UID STORE — @add true → +FLAGS, false → -FLAGS.
     * @flag_atom e.g. `\\Seen` or `\\Flagged` (already backslash-escaped for wire).
     */
    public void uid_store_flags (
        GenericArray<string> uids,
        string flag_atom,
        bool add,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        if (uids.length == 0)
            return;
        var set = uid_set (uids);
        var op = add ? "+FLAGS" : "-FLAGS";
        var resp = command (
            "UID STORE %s %s (%s)".printf (set, op, flag_atom),
            cancellable
        );
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("UID STORE failed: %s".printf (resp.text));
        }
    }

    public void uid_copy (
        GenericArray<string> uids,
        string destination_mailbox,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        if (uids.length == 0)
            return;
        var resp = command (
            "UID COPY %s %s".printf (uid_set (uids), quote (destination_mailbox)),
            cancellable
        );
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("UID COPY failed: %s".printf (resp.text));
        }
    }

    /**
     * Prefer UID MOVE (RFC 6851 / Gmail). Falls back to COPY + \\Deleted + EXPUNGE.
     */
    public void uid_move (
        GenericArray<string> uids,
        string destination_mailbox,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        if (uids.length == 0)
            return;
        var set = uid_set (uids);
        var dest = quote (destination_mailbox);
        var resp = command ("UID MOVE %s %s".printf (set, dest), cancellable);
        if (resp.ok)
            return;
        /* Fallback for servers without MOVE. */
        uid_copy (uids, destination_mailbox, cancellable);
        uid_store_flags (uids, "\\Deleted", true, cancellable);
        resp = command ("UID EXPUNGE %s".printf (set), cancellable);
        if (!resp.ok) {
            /* Some servers lack UID EXPUNGE — plain EXPUNGE of deleted in mailbox. */
            resp = command ("EXPUNGE", cancellable);
        }
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL (
                "UID MOVE fallback failed: %s".printf (resp.text)
            );
        }
    }

    private static string uid_set (GenericArray<string> uids) {
        var sb = new StringBuilder ();
        for (uint i = 0; i < uids.length; i++) {
            if (i > 0)
                sb.append_c (',');
            sb.append (uids[i]);
        }
        return sb.str;
    }

    /**
     * @return RFC822 bytes, or null when the server OK'd but sent no literal
     * (UID vanished / NIL BODY — common mid-prefetch after move/delete).
     */
    public string? fetch_body_uid (string uid, Cancellable? cancellable = null) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        if (uid == null || uid.length == 0) {
            throw new LetterImap.Error.PROTOCOL ("Empty IMAP UID");
        }

        string? body = null;
        var resp = command_collect (
            "UID FETCH %s BODY.PEEK[]".printf (uid),
            cancellable,
            (line) => {
                if (!(line.has_prefix ("* ") && line.contains (" FETCH ")))
                    return;
                size_t lit = literal_size_at_end (line);
                if (lit == 0)
                    return;
                try {
                    body = read_exact (lit, cancellable);
                    read_line (cancellable);
                } catch (GLib.Error e) {
                    warning ("Body literal read failed: %s", e.message);
                }
            }
        );

        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("UID FETCH body failed: %s".printf (resp.text));
        }
        return body;
    }

    public void expunge (Cancellable? cancellable = null) throws GLib.Error {
        var resp = command ("EXPUNGE", cancellable);
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("EXPUNGE failed: %s".printf (resp.text));
        }
    }

    /** Mark every message in the selected mailbox \\Deleted (Empty Trash/Junk). */
    public void store_all_deleted (Cancellable? cancellable = null) throws GLib.Error {
        if (this.selected == null) {
            throw new LetterImap.Error.PROTOCOL ("No mailbox selected");
        }
        var resp = command ("STORE 1:* +FLAGS.SILENT (\\Deleted)", cancellable);
        if (!resp.ok) {
            throw new LetterImap.Error.PROTOCOL ("STORE 1:* \\Deleted failed: %s".printf (resp.text));
        }
    }

    /**
     * APPEND RFC822 into mailbox.
     * @flags e.g. `\\Seen` or `\\Draft \\Seen` (wire atoms).
     * @return UID from APPENDUID when the server reports it; otherwise null.
     */
    public string? append_rfc822 (
        string mailbox,
        string rfc822,
        string flags = "\\Seen",
        Cancellable? cancellable = null
    ) throws GLib.Error {
        /* CRLF body without split() — split("\n") invents a trailing empty
         * field and used to advertise a larger literal than we wrote. */
        var normalized = rfc822.replace ("\r\n", "\n").replace ("\r", "\n");
        var payload = normalized.replace ("\n", "\r\n");
        if (!payload.has_suffix ("\r\n"))
            payload += "\r\n";
        var nbytes = payload.length;
        var tag = "A%u".printf (this.next_tag++);
        var flag_list = (flags != null && flags.strip ().length > 0) ? flags.strip () : "\\Seen";
        write_line (
            "%s APPEND %s (%s) {%u}".printf (tag, quote (mailbox), flag_list, nbytes),
            cancellable
        );
        var cont = read_line (cancellable);
        if (cont == null || !cont.has_prefix ("+")) {
            throw new LetterImap.Error.PROTOCOL (
                "APPEND expected continuation, got: %s".printf (cont ?? "(null)")
            );
        }
        unowned uint8[] bytes = payload.data;
        size_t wrote = 0;
        var raw_out = this.connection.get_output_stream ();
        raw_out.write_all (bytes[0:nbytes], out wrote, cancellable);
        if (wrote != nbytes) {
            throw new LetterImap.Error.IO (
                "Short APPEND write (%zu/%u)".printf (wrote, nbytes)
            );
        }
        /* Python imaplib sends an extra CRLF after the literal (not counted in
         * {n}). Without it Gmail never returns the tagged OK and APPEND hangs. */
        unowned uint8[] crlf = "\r\n".data;
        size_t crlf_wrote = 0;
        raw_out.write_all (crlf[0:2], out crlf_wrote, cancellable);
        raw_out.flush (cancellable);
        this.output.flush (cancellable);
        while (true) {
            var line = read_line (cancellable);
            if (line == null) {
                throw new LetterImap.Error.IO ("Connection closed during APPEND");
            }
            if (line.has_prefix (tag + " ")) {
                if (!line.substring (tag.length + 1).has_prefix ("OK")) {
                    throw new LetterImap.Error.PROTOCOL ("APPEND failed: %s".printf (line));
                }
                return parse_appenduid (line);
            }
        }
    }

    /* OK [APPENDUID <uidvalidity> <uid>] … → uid string, or null. */
    private static string? parse_appenduid (string ok_line) {
        var marker = "[APPENDUID ";
        var idx = ok_line.index_of (marker);
        if (idx < 0)
            return null;
        var rest = ok_line.substring (idx + marker.length);
        var end = rest.index_of_char (']');
        if (end > 0)
            rest = rest.substring (0, end);
        var parts = rest.strip ().split_set (" \t");
        if (parts.length < 2)
            return null;
        var uid = parts[1].strip ();
        return uid.length > 0 ? uid : null;
    }

    public void logout (Cancellable? cancellable = null) {
        try {
            command ("LOGOUT", cancellable);
        } catch (GLib.Error e) {
        }
        try {
            this.connection?.close (null);
        } catch (GLib.Error e) {
        }
        this.connection = null;
        this.input = null;
        this.output = null;
        this.selected = null;
    }

    private Header? parse_fetch_header_line (string line, Cancellable? cancellable) {
        var header = new Header ();
        uint seq = 0;
        var rest = line.substring (2);
        var sp = rest.index_of_char (' ');
        if (sp > 0)
            uint.try_parse (rest.substring (0, sp), out seq);
        header.seq = seq;
        header.uid = extract_atom_after (line, "UID ");
        header.internal_date = extract_quoted_after (line, "INTERNALDATE ");
        apply_flags (header, line);

        size_t lit = literal_size_at_end (line);
        if (lit > 0) {
            try {
                var raw = read_exact (lit, cancellable);
                apply_header_fields (header, raw);
                read_line (cancellable);
            } catch (GLib.Error e) {
                warning ("Header literal read failed: %s", e.message);
            }
        }

        return header;
    }

    private static string? extract_quoted_after (string line, string marker) {
        var idx = line.index_of (marker);
        if (idx < 0)
            return null;
        var start = idx + marker.length;
        while (start < line.length && line[start] == ' ')
            start++;
        if (start >= line.length || line[start] != '"')
            return null;
        start++;
        var end = line.index_of_char ('"', start);
        if (end <= start)
            return null;
        return line.substring (start, end - start);
    }

    private static string? extract_atom_after (string line, string marker) {
        var idx = line.index_of (marker);
        if (idx < 0)
            return null;
        var start = idx + marker.length;
        var end = start;
        /* UIDs are ASCII digits / atoms. */
        while (end < line.length) {
            var c = line[end];
            if (c == ' ' || c == ')' || c == '\r' || c == '\n')
                break;
            end++;
        }
        if (end <= start)
            return null;
        return line.substring (start, end - start);
    }

    private static void apply_flags (Header header, string line) {
        var idx = line.index_of ("FLAGS (");
        if (idx < 0)
            return;
        var start = idx + 7;
        var end = line.index_of_char (')', start);
        if (end < 0)
            return;
        var flags = line.substring (start, end - start).down ();
        header.seen = flags.contains ("\\seen");
        header.flagged = flags.contains ("\\flagged");
    }

    private class TaggedResponse {
        public bool ok;
        public string text;
    }

    private delegate void LineHandler (string line);

    private TaggedResponse command (string payload, Cancellable? cancellable) throws GLib.Error {
        return command_collect (payload, cancellable, () => {});
    }

    private TaggedResponse command_collect (
        string payload,
        Cancellable? cancellable,
        LineHandler on_line
    ) throws GLib.Error {
        var tag = "A%u".printf (this.next_tag++);
        write_line ("%s %s".printf (tag, payload), cancellable);

        var result = new TaggedResponse ();
        while (true) {
            var line = read_line (cancellable);
            if (line == null) {
                throw new LetterImap.Error.IO ("Connection closed during %s".printf (tag));
            }

            if (line.has_prefix (tag + " ")) {
                var status = line.substring (tag.length + 1);
                result.ok = status.has_prefix ("OK");
                result.text = status;
                return result;
            }

            on_line (line);
        }
    }

    private void write_line (string line, Cancellable? cancellable) throws GLib.Error {
        this.output.put_string (line + "\r\n", cancellable);
        this.output.flush (cancellable);
    }

    private string? read_line (Cancellable? cancellable) throws GLib.Error {
        return this.input.read_line (null, cancellable);
    }

    private string read_exact (size_t length, Cancellable? cancellable) throws GLib.Error {
        var buf = new uint8[length + 1];
        size_t got = 0;
        while (got < length) {
            var n = this.input.read (buf[got:length], cancellable);
            if (n <= 0) {
                throw new LetterImap.Error.IO (
                    "Short IMAP literal read (%zu/%zu)".printf (got, length)
                );
            }
            got += n;
        }
        buf[length] = 0;
        return (string) buf;
    }

    private static size_t literal_size_at_end (string line) {
        if (!line.has_suffix ("}"))
            return 0;
        var brace = line.last_index_of_char ('{');
        if (brace < 0)
            return 0;
        var num = line.substring (brace + 1, line.length - brace - 2);
        uint64 n = 0;
        if (!uint64.try_parse (num, out n))
            return 0;
        return (size_t) n;
    }

    private static string quote (string value) {
        var escaped = value.replace ("\\", "\\\\").replace ("\"", "\\\"");
        return "\"%s\"".printf (escaped);
    }

    private static void parse_status_line (string line, MailboxStatus status) {
        /* * STATUS "INBOX" (MESSAGES 31 UNSEEN 12) */
        var open = line.index_of_char ('(');
        var close = line.last_index_of_char (')');
        if (open < 0 || close <= open)
            return;
        var inner = line.substring (open + 1, close - open - 1);
        var parts = inner.split_set (" \t");
        for (uint i = 0; i + 1 < parts.length; i++) {
            var key = parts[i].up ();
            uint n = 0;
            if (!uint.try_parse (parts[i + 1], out n))
                continue;
            if (key == "MESSAGES")
                status.messages = n;
            else if (key == "UNSEEN")
                status.unseen = n;
            i++;
        }
    }

    /**
     * IMAP mailbox names use Modified UTF-7 (RFC 3501).
     * `Pap&AOA-` → `Papà`. ASCII-only names are returned unchanged.
     */
    public static string decode_mailbox_name (string raw) {
        if (raw.index_of_char ('&') < 0)
            return raw;

        var out = new StringBuilder ();
        int i = 0;
        while (i < raw.length) {
            if (raw[i] != '&') {
                out.append_c (raw[i]);
                i++;
                continue;
            }
            i++;
            if (i < raw.length && raw[i] == '-') {
                out.append_c ('&');
                i++;
                continue;
            }
            var start = i;
            while (i < raw.length && raw[i] != '-')
                i++;
            if (i >= raw.length) {
                out.append (raw.substring (start - 1));
                break;
            }
            var encoded = raw.substring (start, i - start);
            i++; /* skip '-' */
            var decoded = decode_modified_utf7_shift (encoded);
            if (decoded != null)
                out.append (decoded);
            else
                out.append ("&").append (encoded).append ("-");
        }
        return out.str;
    }

    private static string? decode_modified_utf7_shift (string encoded) {
        /* Modified Base64: +,/ → -,_; no padding in the IMAP form. */
        var b64 = encoded.replace (",", "/");
        while (b64.length % 4 != 0)
            b64 += "=";
        uint8[] bytes;
        try {
            bytes = Base64.decode (b64);
        } catch (Error e) {
            return null;
        }
        if (bytes.length < 2 || (bytes.length % 2) != 0)
            return null;

        /* UTF-16BE → UTF-8 */
        var utf16 = new StringBuilder ();
        for (uint i = 0; i + 1 < bytes.length; i += 2) {
            unichar ch = ((uint) bytes[i] << 8) | bytes[i + 1];
            utf16.append_unichar (ch);
        }
        return utf16.str;
    }

    private static string? extract_list_mailbox (string line) {
        /* * LIST (\HasNoChildren) "/" "INBOX"
         * * LIST () NIL INBOX
         * * LIST (\Noselect \HasChildren) "/" "[Gmail]" */
        if (!line.has_prefix ("* LIST"))
            return null;
        var rest = line.substring (6).strip (); /* after "* LIST" */

        if (rest.has_prefix ("(")) {
            int depth = 0;
            int i = 0;
            for (; i < rest.length; i++) {
                unichar c = rest.get_char (i);
                if (c == '(')
                    depth++;
                else if (c == ')') {
                    depth--;
                    if (depth == 0) {
                        i++;
                        break;
                    }
                }
            }
            if (depth != 0)
                return null;
            rest = rest.substring (i).strip ();
        }

        if (rest.has_prefix ("\"")) {
            int end = -1;
            for (int i = 1; i < rest.length; i++) {
                if (rest[i] == '\\') {
                    i++;
                    continue;
                }
                if (rest[i] == '"') {
                    end = i;
                    break;
                }
            }
            if (end < 0)
                return null;
            rest = rest.substring (end + 1).strip ();
        } else if (rest.has_prefix ("NIL")
            && (rest.length == 3 || rest[3].isspace ())) {
            rest = rest.substring (3).strip ();
        } else {
            return null;
        }

        if (rest.has_prefix ("\"")) {
            var sb = new StringBuilder ();
            for (int i = 1; i < rest.length; i++) {
                if (rest[i] == '\\' && i + 1 < rest.length) {
                    sb.append_c (rest[i + 1]);
                    i++;
                } else if (rest[i] == '"') {
                    return sb.str;
                } else {
                    sb.append_c (rest[i]);
                }
            }
            return null;
        }

        if (rest.length == 0)
            return null;
        return rest;
    }

    private static void apply_header_fields (Header header, string raw) {
        string? current = null;
        var value = new StringBuilder ();

        foreach (var line in raw.split ("\n")) {
            var trimmed_nl = line.has_suffix ("\r") ? line.substring (0, line.length - 1) : line;
            if (trimmed_nl.length > 0 && (trimmed_nl[0] == ' ' || trimmed_nl[0] == '\t')) {
                if (current != null) {
                    value.append_c (' ');
                    value.append (trimmed_nl.strip ());
                }
                continue;
            }

            flush_header_field (header, current, value.str);
            value.truncate ();
            current = null;

            var colon = trimmed_nl.index_of_char (':');
            if (colon <= 0)
                continue;
            current = trimmed_nl.substring (0, colon).strip ().down ();
            value.append (trimmed_nl.substring (colon + 1).strip ());
        }
        flush_header_field (header, current, value.str);
    }

    private static void flush_header_field (Header header, string? name, string value) {
        if (name == null || value.length == 0)
            return;
        switch (name) {
            case "from":
                header.from = value;
                break;
            case "subject":
                header.subject = value;
                break;
            case "date":
                header.date = value;
                break;
            case "to":
                header.to = value;
                break;
            case "message-id":
                header.message_id = value;
                break;
            case "in-reply-to":
                header.in_reply_to = value;
                break;
            case "references":
                header.references = value;
                break;
            case "content-type":
                header.content_type = value;
                if (content_type_suggests_attachment (value))
                    header.has_attachment = true;
                break;
            case "content-disposition":
                if (value.down ().contains ("attachment"))
                    header.has_attachment = true;
                break;
        }
    }

    /**
     * List-row paperclip without BODYSTRUCTURE: multipart/mixed (or a named
     * application part) almost always means a real file attachment. Pure
     * multipart/related (signature images) stays false.
     */
    private static bool content_type_suggests_attachment (string content_type) {
        var down = content_type.down ();
        if (down.contains ("multipart/mixed")
            || down.contains ("multipart/report")
            || down.contains ("message/rfc822"))
            return true;
        if (down.has_prefix ("application/") && down.contains ("name="))
            return true;
        if (down.has_prefix ("image/") && down.contains ("name="))
            return true;
        return false;
    }
}
