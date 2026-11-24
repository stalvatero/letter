/**
 * Live check of IMAP + SMTP for Letter Identity password accounts.
 * Used by add/edit dialogs before persisting server settings.
 */
public class Mail.IdentityMailVerify : Object {
    /**
     * Connect and authenticate on IMAP then SMTP.
     * Failures are prefixed with “IMAP:” or “SMTP:” for UI copy.
     */
    public static void verify_password (
        string username,
        string password,
        string imap_host,
        uint16 imap_port,
        string smtp_host,
        uint16 smtp_port
    ) throws Error {
        if (imap_host.strip ().length == 0) {
            throw new IOError.INVALID_ARGUMENT (_("Enter an IMAP host."));
        }
        if (smtp_host.strip ().length == 0) {
            throw new IOError.INVALID_ARGUMENT (_("Enter an SMTP host."));
        }
        if (password.length == 0) {
            throw new IOError.INVALID_ARGUMENT (_("Enter a password."));
        }

        try {
            var imap = new LetterImap.Client ();
            imap.connect_tls (imap_host, imap_port);
            imap.login (username, password);
            imap.logout ();
        } catch (Error e) {
            throw stage_error ("IMAP", e);
        }

        try {
            var starttls = smtp_port == 587;
            var smtp = new LetterSmtp.Client ();
            try {
                smtp.connect_host (smtp_host, smtp_port, starttls);
                smtp.ehlo (smtp_host);
                smtp.auth_login (username, password);
            } finally {
                smtp.quit ();
            }
        } catch (Error e) {
            throw stage_error ("SMTP", e);
        }
    }

    /** Same fallback as the send path when smtp_host was left blank. */
    public static string resolve_smtp_host (string? smtp_host, string? imap_host) {
        if (smtp_host != null && smtp_host.strip ().length > 0)
            return smtp_host.strip ();
        var imap = imap_host ?? "";
        if (imap.has_prefix ("imap."))
            return "smtp." + imap.substring (5);
        if (imap.length > 0)
            return imap;
        return "";
    }

    public static string explain (Error e) {
        var raw = e.message ?? "";
        var upper = raw.up ();
        var smtp = upper.has_prefix ("SMTP:");
        var imap = upper.has_prefix ("IMAP:") || !smtp;
        var body = raw;
        if (raw.has_prefix ("IMAP:") || raw.has_prefix ("SMTP:")) {
            var colon = raw.index_of_char (':');
            if (colon >= 0 && colon + 1 < raw.length)
                body = raw.substring (colon + 1).strip ();
        }
        var body_up = body.up ();

        if (body_up.contains ("APP PASSWORD") || body_up.contains ("APPLICATION PASSWORD")
            || body_up.contains ("APP-SPECIFIC")) {
            return _("This provider requires an app password (not the web login password).");
        }
        if (body_up.contains ("LOOKUP") || body_up.contains ("RESOLV")
            || body_up.contains ("NAME OR SERVICE") || body_up.contains ("NO ADDRESS")) {
            return smtp
                ? _("Could not reach the SMTP host. Check the server name and your network.")
                : _("Could not reach the IMAP host. Check the server name and your network.");
        }
        if (body_up.contains ("CONNECTION REFUSED") || body_up.contains ("CONNECT")) {
            return smtp
                ? _("Could not connect to the SMTP host. Check the port (465 TLS or 587 STARTTLS).")
                : _("Could not connect to the IMAP host. Check the port and that the server accepts TLS.");
        }
        if (body_up.contains ("TLS") || body_up.contains ("CERTIFICATE")
            || body_up.contains ("HANDSHAKE")) {
            return smtp
                ? _("Could not open a secure SMTP connection. Try port 465 (TLS) or 587 (STARTTLS).")
                : _("Could not open a secure connection to the IMAP server. Check host and port (usually 993 with TLS).");
        }
        if (body_up.contains ("TIMEOUT") || body_up.contains ("TIMED OUT")) {
            return smtp
                ? _("The SMTP server did not respond in time. Check host, port, and firewall.")
                : _("The IMAP server did not respond in time. Check host, port, and firewall.");
        }
        if (e is LetterImap.Error.AUTH || e is LetterSmtp.Error.AUTH
            || body_up.contains ("AUTHENTICATIONFAILED")
            || body_up.contains ("LOGIN FAILED")
            || body_up.contains ("AUTH LOGIN FAILED")
            || body_up.contains ("AUTHENTICATE")) {
            return smtp
                ? _("SMTP sign-in rejected. Check username, password, and that SMTP AUTH is allowed.")
                : _("IMAP sign-in rejected. Check username and password.");
        }
        if (imap && body.length > 0 && body.length <= 220)
            return body;
        if (smtp && body.length > 0 && body.length <= 220)
            return _("SMTP: %s").printf (body);
        if (raw.length > 180)
            return raw.substring (0, 177) + "…";
        return raw;
    }

    private static Error stage_error (string stage, Error e) {
        return new IOError.FAILED ("%s: %s".printf (stage, e.message ?? ""));
    }
}
