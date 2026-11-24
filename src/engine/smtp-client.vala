/**
 * Bare SMTP over GIO TLS — no Camel.
 * Implicit TLS (port 465) or STARTTLS (587). AUTH LOGIN.
 */
public errordomain LetterSmtp.Error {
    PROTOCOL,
    AUTH,
    IO
}

public class LetterSmtp.Client : Object {
    private IOStream? stream;
    private DataInputStream? input;
    private DataOutputStream? output;

    public void connect_host (
        string host,
        uint16 port,
        bool starttls,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (starttls && port != 465)
            connect_starttls (host, port, cancellable);
        else
            connect_implicit_tls (host, port == 0 ? 465 : port, cancellable);
    }

    public void connect_implicit_tls (
        string host,
        uint16 port = 465,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var client = new SocketClient () {
            tls = true,
            tls_validation_flags = TlsCertificateFlags.VALIDATE_ALL,
        };
        var conn = client.connect_to_host (host, port, cancellable);
        bind_stream (conn);
        expect (220, cancellable);
    }

    public void connect_starttls (
        string host,
        uint16 port = 587,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var client = new SocketClient ();
        var conn = client.connect_to_host (host, port, cancellable);
        bind_stream (conn);
        expect (220, cancellable);
        ehlo (host, cancellable);
        write_line ("STARTTLS", cancellable);
        expect (220, cancellable);

        /* SocketConnectable identity is required for VALIDATE_ALL — without it
         * GIO rejects the peer cert as “unacceptable” (Hotmail/Office365 :587).
         * Implicit TLS (:465) is fine: SocketClient sets identity from the host. */
        var identity = new NetworkAddress (host, port);
        var tls = TlsClientConnection.@new (conn, identity);
        tls.set_validation_flags (TlsCertificateFlags.VALIDATE_ALL);
        tls.handshake (cancellable);
        bind_stream (tls);
    }

    private void bind_stream (IOStream stream) {
        this.stream = stream;
        /* close_base_stream must stay false: after STARTTLS we replace these
         * filters with ones on the TLS connection. Default true would close the
         * TCP streams under TlsClientConnection and yield G_TLS_ERROR_CERTIFICATE_REQUIRED
         * (“Il server richiede un certificato TLS”) on the next EHLO/AUTH. */
        this.input = new DataInputStream (stream.get_input_stream ());
        this.input.set_close_base_stream (false);
        this.input.set_newline_type (DataStreamNewlineType.LF);
        this.output = new DataOutputStream (stream.get_output_stream ());
        this.output.set_close_base_stream (false);
    }

    public void ehlo (string host, Cancellable? cancellable = null) throws GLib.Error {
        var name = (host != null && host.length > 0 && !host.contains (" ")) ? host : "letter";
        write_line ("EHLO %s".printf (name), cancellable);
        read_multiline (250, cancellable);
    }

    public void auth_login (
        string username,
        string password,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        write_line ("AUTH LOGIN", cancellable);
        expect (334, cancellable);
        write_line (Base64.encode (username.data), cancellable);
        expect (334, cancellable);
        write_line (Base64.encode (password.data), cancellable);
        string text;
        var code = read_reply (cancellable, out text);
        if (code != 235) {
            throw new LetterSmtp.Error.AUTH ("AUTH LOGIN failed (%d): %s".printf (code, text));
        }
    }

    public void auth_xoauth2 (
        string username,
        string access_token,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var raw = "user=%s\u0001auth=Bearer %s\u0001\u0001".printf (username, access_token);
        write_line ("AUTH XOAUTH2 %s".printf (Base64.encode (raw.data)), cancellable);
        string text;
        var code = read_reply (cancellable, out text);
        if (code != 235) {
            throw new LetterSmtp.Error.AUTH ("AUTH XOAUTH2 failed (%d): %s".printf (code, text));
        }
    }

    public void send_mail (
        string from_addr,
        GenericArray<string> recipients,
        string rfc822,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        if (recipients.length == 0) {
            throw new LetterSmtp.Error.PROTOCOL ("No SMTP recipients");
        }
        write_line ("MAIL FROM:<%s>".printf (bare_addr (from_addr)), cancellable);
        expect (250, cancellable);
        for (uint i = 0; i < recipients.length; i++) {
            write_line ("RCPT TO:<%s>".printf (bare_addr (recipients[i])), cancellable);
            expect (250, cancellable);
        }
        write_line ("DATA", cancellable);
        expect (354, cancellable);
        var normalized = rfc822.replace ("\r\n", "\n").replace ("\r", "\n");
        var lines = normalized.split ("\n");
        for (uint i = 0; i < lines.length; i++) {
            var line = lines[i];
            if (line.has_prefix ("."))
                line = "." + line;
            this.output.put_string (line + "\r\n", cancellable);
        }
        this.output.put_string (".\r\n", cancellable);
        this.output.flush (cancellable);
        expect (250, cancellable);
    }

    public void quit (Cancellable? cancellable = null) {
        try {
            write_line ("QUIT", cancellable);
            string ignore;
            read_reply (cancellable, out ignore);
        } catch (GLib.Error e) {
        }
        try {
            this.stream?.close (null);
        } catch (GLib.Error e) {
        }
        this.stream = null;
        this.input = null;
        this.output = null;
    }

    private void expect (int want, Cancellable? cancellable) throws GLib.Error {
        string text;
        var code = read_reply (cancellable, out text);
        if (code != want) {
            throw new LetterSmtp.Error.PROTOCOL (
                "SMTP expected %d, got %d: %s".printf (want, code, text)
            );
        }
    }

    private void read_multiline (int want, Cancellable? cancellable) throws GLib.Error {
        while (true) {
            var line = read_line (cancellable);
            if (line == null) {
                throw new LetterSmtp.Error.IO ("SMTP connection closed");
            }
            if (line.length < 3) {
                throw new LetterSmtp.Error.PROTOCOL ("Short SMTP reply: %s".printf (line));
            }
            int code = int.parse (line.substring (0, 3));
            if (line.length >= 4 && line[3] == '-')
                continue;
            if (code != want) {
                throw new LetterSmtp.Error.PROTOCOL (
                    "SMTP expected %d, got %d: %s".printf (want, code, line)
                );
            }
            return;
        }
    }

    private int read_reply (Cancellable? cancellable, out string text) throws GLib.Error {
        var line = read_line (cancellable);
        if (line == null) {
            throw new LetterSmtp.Error.IO ("SMTP connection closed");
        }
        text = line;
        if (line.length < 3) {
            throw new LetterSmtp.Error.PROTOCOL ("Short SMTP reply: %s".printf (line));
        }
        while (line.length >= 4 && line[3] == '-') {
            line = read_line (cancellable);
            if (line == null) {
                throw new LetterSmtp.Error.IO ("SMTP connection closed mid-reply");
            }
            text = line;
        }
        return int.parse (text.substring (0, 3));
    }

    private void write_line (string line, Cancellable? cancellable) throws GLib.Error {
        this.output.put_string (line + "\r\n", cancellable);
        this.output.flush (cancellable);
    }

    private string? read_line (Cancellable? cancellable) throws GLib.Error {
        var line = this.input.read_line (null, cancellable);
        if (line != null && line.has_suffix ("\r"))
            return line.substring (0, line.length - 1);
        return line;
    }

    private static string bare_addr (string raw) {
        var s = raw.strip ();
        var lt = s.index_of_char ('<');
        var gt = s.index_of_char ('>');
        if (lt >= 0 && gt > lt)
            return s.substring (lt + 1, gt - lt - 1).strip ();
        return s;
    }
}

/** Build a minimal RFC822 message for SMTP (no Camel). */
public class LetterSmtp.MimeBuilder : Object {
    public static string build (
        string from_name,
        string from_addr,
        GenericArray<string> to,
        GenericArray<string> cc,
        GenericArray<string> bcc,
        string subject,
        string plain,
        string? html,
        GenericArray<Mail.Attachment>? attachments,
        string? in_reply_to,
        string? references,
        bool high_priority
    ) {
        var sb = new StringBuilder ();
        var date = new DateTime.now_local ().format ("%a, %d %b %Y %H:%M:%S %z");
        var msgid = "<%s@%s>".printf (
            Uuid.string_random (),
            domain_of (from_addr) ?? "localhost"
        );

        sb.append ("From: %s\r\n".printf (format_mailbox (from_name, from_addr)));
        if (to.length > 0)
            sb.append ("To: %s\r\n".printf (join_addrs (to)));
        if (cc.length > 0)
            sb.append ("Cc: %s\r\n".printf (join_addrs (cc)));
        sb.append ("Subject: %s\r\n".printf (encode_header (
            subject.strip ().length > 0 ? subject.strip () : _("(No subject)")
        )));
        sb.append ("Date: %s\r\n".printf (date));
        sb.append ("Message-ID: %s\r\n".printf (msgid));
        sb.append ("MIME-Version: 1.0\r\n");
        if (in_reply_to != null && in_reply_to.length > 0)
            sb.append ("In-Reply-To: %s\r\n".printf (in_reply_to));
        if (references != null && references.length > 0)
            sb.append ("References: %s\r\n".printf (references));
        if (high_priority) {
            sb.append ("X-Priority: 1\r\n");
            sb.append ("Importance: high\r\n");
        }

        var has_html = html != null && html.strip ().length > 0;
        var has_files = attachments != null && attachments.length > 0;
        var plain_body = plain ?? "";

        if (!has_html && !has_files) {
            sb.append ("Content-Type: text/plain; charset=UTF-8\r\n");
            sb.append ("Content-Transfer-Encoding: 8bit\r\n\r\n");
            sb.append (plain_body);
            if (!plain_body.has_suffix ("\n"))
                sb.append ("\r\n");
            return sb.str;
        }

        if (has_files) {
            var mixed = "letter-mixed-%s".printf (Uuid.string_random ());
            sb.append ("Content-Type: multipart/mixed; boundary=\"%s\"\r\n\r\n".printf (mixed));
            sb.append ("--%s\r\n".printf (mixed));
            append_body_part (sb, plain_body, html);
            for (uint i = 0; i < attachments.length; i++) {
                sb.append ("--%s\r\n".printf (mixed));
                append_attachment (sb, attachments[i]);
            }
            sb.append ("--%s--\r\n".printf (mixed));
            return sb.str;
        }

        append_body_headers_and_content (sb, plain_body, html);
        return sb.str;
    }

    private static void append_body_part (StringBuilder sb, string plain, string? html) {
        append_body_headers_and_content (sb, plain, html);
        if (!sb.str.has_suffix ("\n"))
            sb.append ("\r\n");
    }

    private static void append_body_headers_and_content (
        StringBuilder sb,
        string plain,
        string? html
    ) {
        var has_html = html != null && html.strip ().length > 0;
        if (!has_html) {
            sb.append ("Content-Type: text/plain; charset=UTF-8\r\n");
            sb.append ("Content-Transfer-Encoding: 8bit\r\n\r\n");
            sb.append (plain);
            return;
        }
        var alt = "letter-alt-%s".printf (Uuid.string_random ());
        sb.append ("Content-Type: multipart/alternative; boundary=\"%s\"\r\n\r\n".printf (alt));
        sb.append ("--%s\r\n".printf (alt));
        sb.append ("Content-Type: text/plain; charset=UTF-8\r\n");
        sb.append ("Content-Transfer-Encoding: 8bit\r\n\r\n");
        sb.append (plain);
        sb.append ("\r\n--%s\r\n".printf (alt));
        sb.append ("Content-Type: text/html; charset=UTF-8\r\n");
        sb.append ("Content-Transfer-Encoding: 8bit\r\n\r\n");
        sb.append (html);
        sb.append ("\r\n--%s--\r\n".printf (alt));
    }

    private static void append_attachment (StringBuilder sb, Mail.Attachment att) {
        var name = att.save_filename;
        var type = att.mime_type ?? "application/octet-stream";
        sb.append ("Content-Type: %s; name=\"%s\"\r\n".printf (type, escape_quote (name)));
        sb.append ("Content-Transfer-Encoding: base64\r\n");
        sb.append ("Content-Disposition: attachment; filename=\"%s\"\r\n\r\n".printf (
            escape_quote (name)
        ));
        unowned uint8[] raw = att.data.get_data ();
        var b64 = Base64.encode (raw);
        for (int i = 0; i < b64.length; i += 76) {
            var len = int.min (76, b64.length - i);
            sb.append (b64.substring (i, len));
            sb.append ("\r\n");
        }
    }

    public static GenericArray<string> parse_address_list (string? raw) {
        var list = new GenericArray<string> ();
        if (raw == null || raw.strip ().length == 0)
            return list;
        var parts = raw.split (",");
        for (uint i = 0; i < parts.length; i++) {
            var p = parts[i].strip ();
            if (p.length == 0)
                continue;
            list.add (p);
        }
        return list;
    }

    public static string extract_email (string mailbox) {
        var s = mailbox.strip ();
        var lt = s.index_of_char ('<');
        var gt = s.index_of_char ('>');
        if (lt >= 0 && gt > lt)
            return s.substring (lt + 1, gt - lt - 1).strip ();
        return s;
    }

    private static string join_addrs (GenericArray<string> addrs) {
        var sb = new StringBuilder ();
        for (uint i = 0; i < addrs.length; i++) {
            if (i > 0)
                sb.append (", ");
            sb.append (addrs[i]);
        }
        return sb.str;
    }

    private static string format_mailbox (string name, string addr) {
        if (name == null || name.strip ().length == 0 || name == addr)
            return addr;
        return "%s <%s>".printf (encode_header (name), addr);
    }

    private static string? domain_of (string addr) {
        var at = addr.last_index_of_char ('@');
        if (at < 0 || at + 1 >= addr.length)
            return null;
        return addr.substring (at + 1);
    }

    private static string escape_quote (string s) {
        return s.replace ("\\", "\\\\").replace ("\"", "\\\"");
    }

    private static string encode_header (string raw) {
        bool non_ascii = false;
        for (int i = 0; i < raw.length; i++) {
            if ((uint8) raw[i] >= 0x80) {
                non_ascii = true;
                break;
            }
        }
        if (!non_ascii)
            return raw;
        return "=?UTF-8?B?%s?=".printf (Base64.encode (raw.data));
    }
}
