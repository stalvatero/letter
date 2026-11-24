/**
 * Letter Identity OAuth (PKCE loopback) — Google + Microsoft public clients.
 * Refresh tokens stay in libsecret; never log secret values.
 *
 * Client IDs (until Letter-owned apps are baked in):
 *   LETTER_GOOGLE_CLIENT_ID + LETTER_GOOGLE_CLIENT_SECRET — Google Desktop OAuth client
 *     (Google’s token endpoint still requires the Desktop “client secret”)
 *   LETTER_MS_CLIENT_ID — Letter Azure public app (same id for Hotmail + M365)
 *   LETTER_MS_CLIENT_SECRET — optional (public clients omit it)
 *   LETTER_MS_TENANT — default common (Hotmail + work); consumers|organizations OK
 *
 * Microsoft loopback is a fixed port so the Azure redirect URI is registered once:
 *   http://127.0.0.1:8743/letter-oauth
 */
public errordomain Mail.IdentityOAuthError {
    CANCELLED,
    CONFIG,
    HTTP,
    TOKEN,
    STATE
}

public class Mail.IdentityOAuthTokens : Object {
    public string access_token { get; set; }
    public string? refresh_token { get; set; }
    public string? id_token { get; set; }
    public int64 expires_at { get; set; }
    public string? token_type { get; set; }
}

public class Mail.IdentityOAuthProfile : Object {
    public string email { get; set; }
    public string? display_name { get; set; }
    public IdentityOAuthTokens tokens { get; set; }
}

public class Mail.IdentityOAuth : Object {
    public const string GOOGLE_SCOPE =
        "openid email profile https://mail.google.com/";
    /**
     * One resource per token (Microsoft rule). Hotmail/IMAP today uses
     * outlook.office.com; Graph Mail.* is a later refresh with Graph scopes
     * on the same Azure app (already registered for IT consent).
     */
    public const string MICROSOFT_SCOPE =
        "offline_access openid email profile "
        + "https://outlook.office.com/IMAP.AccessAsUser.All "
        + "https://outlook.office.com/SMTP.Send";
    /** Fixed loopback — register this exact URI on the Letter Azure app. */
    public const uint16 MICROSOFT_REDIRECT_PORT = 8743;
    public const string MICROSOFT_REDIRECT_URI =
        "http://127.0.0.1:8743/letter-oauth";

    private Soup.Session session = new Soup.Session ();

    public static string? google_client_id () {
        var id = Environment.get_variable ("LETTER_GOOGLE_CLIENT_ID");
        if (id != null && id.length > 0) {
            remember_oauth_client ("google", id);
            return id;
        }
        return load_cached_oauth_client ("google");
    }

    public static string? google_client_secret () {
        var s = Environment.get_variable ("LETTER_GOOGLE_CLIENT_SECRET");
        if (s != null && s.length > 0) {
            /* Desktop client “secret” is not confidential; cache like the id
             * so overnight refresh works without re-exporting env. */
            remember_oauth_client ("google_secret", s);
            return s;
        }
        return load_cached_oauth_client ("google_secret");
    }

    public static string? microsoft_client_id () {
        var id = Environment.get_variable ("LETTER_MS_CLIENT_ID");
        if (id != null && id.length > 0) {
            /* Keep disk cache warm whenever the env is present. */
            remember_oauth_client ("microsoft", id);
            return id;
        }
        /* Remembered at last successful Microsoft sign-in / env session so
         * overnight refresh works without re-exporting every launch. */
        return load_cached_oauth_client ("microsoft");
    }

    public static string? microsoft_client_secret () {
        var s = Environment.get_variable ("LETTER_MS_CLIENT_SECRET");
        return (s != null && s.length > 0) ? s : null;
    }

    public static string microsoft_tenant () {
        var t = Environment.get_variable ("LETTER_MS_TENANT");
        /* common = personal MSA (Hotmail) + work/school. Override with
         * consumers or organizations only when deliberately narrowing. */
        return (t != null && t.length > 0) ? t : "common";
    }

    private static string oauth_clients_path () {
        return Path.build_filename (
            Environment.get_user_data_dir (),
            "letter",
            "identity",
            "oauth-clients.json"
        );
    }

    private static string? load_cached_oauth_client (string provider) {
        try {
            string contents;
            if (!FileUtils.get_contents (oauth_clients_path (), out contents))
                return null;
            var parser = new Json.Parser ();
            parser.load_from_data (contents);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return null;
            var obj = root.get_object ();
            if (!obj.has_member (provider))
                return null;
            var id = obj.get_string_member (provider);
            return (id != null && id.length > 0) ? id : null;
        } catch (Error e) {
            return null;
        }
    }

    private static void remember_oauth_client (string provider, string client_id) {
        if (client_id.length == 0)
            return;
        try {
            var dir = Path.get_dirname (oauth_clients_path ());
            DirUtils.create_with_parents (dir, 0700);
            Json.Object obj;
            try {
                string contents;
                FileUtils.get_contents (oauth_clients_path (), out contents);
                var parser = new Json.Parser ();
                parser.load_from_data (contents);
                var root = parser.get_root ();
                obj = (root != null && root.get_node_type () == Json.NodeType.OBJECT)
                    ? root.get_object ()
                    : new Json.Object ();
            } catch (Error e) {
                obj = new Json.Object ();
            }
            obj.set_string_member (provider, client_id);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (obj);
            var gen = new Json.Generator ();
            gen.set_root (node);
            gen.pretty = true;
            FileUtils.set_contents (oauth_clients_path (), gen.to_data (null));
        } catch (Error e) {
            warning ("Could not remember OAuth client id: %s", e.message);
        }
    }

    public async IdentityOAuthProfile sign_in_google (Cancellable? cancellable = null) throws Error {
        var client_id = google_client_id ();
        if (client_id == null) {
            throw new IdentityOAuthError.CONFIG (
                _("Set LETTER_GOOGLE_CLIENT_ID to a Google Cloud Desktop OAuth client id.")
            );
        }
        var client_secret = google_client_secret ();
        if (client_secret == null) {
            throw new IdentityOAuthError.CONFIG (
                _("Set LETTER_GOOGLE_CLIENT_SECRET (shown next to the Desktop client id in Google Cloud).")
            );
        }
        var tokens = yield authorize_pkce (
            "https://accounts.google.com/o/oauth2/v2/auth",
            "https://oauth2.googleapis.com/token",
            client_id,
            client_secret,
            GOOGLE_SCOPE,
            true,
            0,
            cancellable
        );
        remember_oauth_client ("google", client_id);
        remember_oauth_client ("google_secret", client_secret);
        var profile = yield fetch_google_profile (tokens.access_token, cancellable);
        profile.tokens = tokens;
        return profile;
    }

    public async IdentityOAuthProfile sign_in_microsoft (Cancellable? cancellable = null) throws Error {
        var client_id = microsoft_client_id ();
        if (client_id == null) {
            throw new IdentityOAuthError.CONFIG (
                _("Set LETTER_MS_CLIENT_ID to a Letter Azure public client id.")
            );
        }
        var tenant = microsoft_tenant ();
        var tokens = yield authorize_pkce (
            "https://login.microsoftonline.com/%s/oauth2/v2.0/authorize".printf (tenant),
            "https://login.microsoftonline.com/%s/oauth2/v2.0/token".printf (tenant),
            client_id,
            microsoft_client_secret (),
            MICROSOFT_SCOPE,
            false,
            MICROSOFT_REDIRECT_PORT,
            cancellable
        );
        remember_oauth_client ("microsoft", client_id);
        /* IMAP audience token cannot call Graph /me — use OIDC id_token. */
        var profile = profile_from_microsoft_id_token (tokens.id_token);
        profile.tokens = tokens;
        return profile;
    }

    /**
     * Return a usable access token, refreshing via libsecret when needed.
     */
    public static string ensure_access_token_sync (IdentityAccount account) throws Error {
        var stored = IdentitySecrets.lookup_oauth_tokens (account.id);
        if (stored == null || stored.access_token == null || stored.access_token.length == 0) {
            throw new IdentityOAuthError.TOKEN (
                _("No OAuth tokens for “%s”.").printf (account.email)
            );
        }
        var now = new DateTime.now_utc ().to_unix ();
        if (stored.expires_at > now + 60)
            return stored.access_token;
        return refresh_access_token_sync (account, stored);
    }

    /** Ignore expires_at and refresh (XOAUTH2 rejected a still-cached access token). */
    public static string force_refresh_access_token_sync (IdentityAccount account) throws Error {
        var stored = IdentitySecrets.lookup_oauth_tokens (account.id);
        if (stored == null || stored.refresh_token == null || stored.refresh_token.length == 0) {
            throw new IdentityOAuthError.TOKEN (
                _("OAuth access expired and no refresh token for “%s”.").printf (account.email)
            );
        }
        return refresh_access_token_sync (account, stored);
    }

    private static string refresh_access_token_sync (
        IdentityAccount account,
        IdentityOAuthTokens stored
    ) throws Error {
        if (stored.refresh_token == null || stored.refresh_token.length == 0) {
            throw new IdentityOAuthError.TOKEN (
                _("OAuth access expired and no refresh token for “%s”.").printf (account.email)
            );
        }

        var oauth = new IdentityOAuth ();
        IdentityOAuthTokens refreshed;
        var kind = (account.kind ?? "").down ();
        if (kind == "google") {
            var client_id = google_client_id ();
            if (client_id == null)
                throw new IdentityOAuthError.CONFIG (_("LETTER_GOOGLE_CLIENT_ID is not set."));
            var client_secret = google_client_secret ();
            if (client_secret == null)
                throw new IdentityOAuthError.CONFIG (_("LETTER_GOOGLE_CLIENT_SECRET is not set."));
            refreshed = oauth.refresh_sync (
                "https://oauth2.googleapis.com/token",
                client_id,
                client_secret,
                stored.refresh_token,
                null
            );
        } else if (kind == "microsoft" || kind == "ms365") {
            var client_id = microsoft_client_id ();
            if (client_id == null)
                throw new IdentityOAuthError.CONFIG (_("LETTER_MS_CLIENT_ID is not set."));
            var tenant = microsoft_tenant ();
            refreshed = oauth.refresh_sync (
                "https://login.microsoftonline.com/%s/oauth2/v2.0/token".printf (tenant),
                client_id,
                microsoft_client_secret (),
                stored.refresh_token,
                MICROSOFT_SCOPE
            );
        } else {
            throw new IdentityOAuthError.CONFIG (
                _("Unknown OAuth account kind “%s”.").printf (account.kind ?? "")
            );
        }
        if (refreshed.refresh_token == null || refreshed.refresh_token.length == 0)
            refreshed.refresh_token = stored.refresh_token;
        IdentitySecrets.store_oauth_tokens (
            account.id,
            _("Letter OAuth: %s").printf (account.email),
            refreshed
        );
        return refreshed.access_token;
    }

    private IdentityOAuthTokens refresh_sync (
        string token_url,
        string client_id,
        string? client_secret,
        string refresh_token,
        string? scope
    ) throws Error {
        var body = new StringBuilder ();
        body.append_printf ("client_id=%s", Uri.escape_string (client_id));
        if (client_secret != null && client_secret.length > 0)
            body.append_printf ("&client_secret=%s", Uri.escape_string (client_secret));
        body.append ("&grant_type=refresh_token");
        body.append_printf ("&refresh_token=%s", Uri.escape_string (refresh_token));
        if (scope != null && scope.length > 0)
            body.append_printf ("&scope=%s", Uri.escape_string (scope));
        var msg = new Soup.Message.from_encoded_form ("POST", token_url, body.str);
        var loop = new MainLoop ();
        Bytes? bytes = null;
        Error? err = null;
        this.session.send_and_read_async.begin (msg, Priority.DEFAULT, null, (obj, res) => {
            try {
                bytes = this.session.send_and_read_async.end (res);
            } catch (Error e) {
                err = e;
            }
            loop.quit ();
        });
        loop.run ();
        if (err != null)
            throw new IdentityOAuthError.HTTP ("Token refresh failed: %s".printf (err.message));
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new IdentityOAuthError.TOKEN (
                "Token refresh HTTP %u: %s".printf (msg.status_code, bytes_to_string (bytes))
            );
        }
        return parse_token_json (bytes_to_string (bytes));
    }

    private async IdentityOAuthTokens authorize_pkce (
        string authorize_url,
        string token_url,
        string client_id,
        string? client_secret,
        string scope,
        bool include_access_type_offline,
        uint16 preferred_port,
        Cancellable? cancellable
    ) throws Error {
        var verifier = IdentityPkce.create_verifier ();
        var challenge = IdentityPkce.challenge_s256 (verifier);
        var state = IdentityPkce.create_state ();

        var server = new Soup.Server (null);
        string? auth_code = null;
        string? returned_state = null;
        string? oauth_error = null;
        var loop = new MainLoop ();

        server.add_handler ("/letter-oauth", (serv, msg, path, query) => {
            if (query != null) {
                auth_code = query.lookup ("code");
                returned_state = query.lookup ("state");
                oauth_error = query.lookup ("error");
            }
            var body = oauth_success_html ();
            msg.set_status (Soup.Status.OK, null);
            msg.set_response ("text/html; charset=utf-8", Soup.MemoryUse.COPY, body.data);
            Idle.add (() => {
                loop.quit ();
                return false;
            });
        });

        try {
            server.listen_local (preferred_port, Soup.ServerListenOptions.IPV4_ONLY);
        } catch (Error e) {
            if (preferred_port == 0)
                throw e;
            throw new IdentityOAuthError.HTTP (
                _("Could not bind OAuth redirect on port %u (is another Letter sign-in open?): %s")
                    .printf (preferred_port, e.message)
            );
        }
        var uris = server.get_uris ();
        if (uris == null || uris.length () == 0) {
            throw new IdentityOAuthError.HTTP (_("Could not bind localhost OAuth redirect."));
        }
        var listen_port = (uint16) uris.data.get_port ();
        var redirect = "http://127.0.0.1:%u/letter-oauth".printf (listen_port);

        var q = new StringBuilder ();
        q.append_printf ("client_id=%s", Uri.escape_string (client_id));
        q.append ("&response_type=code");
        q.append_printf ("&redirect_uri=%s", Uri.escape_string (redirect));
        q.append_printf ("&scope=%s", Uri.escape_string (scope));
        q.append_printf ("&state=%s", Uri.escape_string (state));
        q.append_printf ("&code_challenge=%s", Uri.escape_string (challenge));
        q.append ("&code_challenge_method=S256");
        if (include_access_type_offline) {
            q.append ("&access_type=offline");
            q.append ("&prompt=consent");
        } else {
            /* Microsoft: pick account; consent when new scopes appear. */
            q.append ("&prompt=select_account");
        }
        var auth_url = "%s?%s".printf (authorize_url, q.str);

        try {
            AppInfo.launch_default_for_uri (auth_url, null);
        } catch (Error e) {
            warning ("Could not open browser for OAuth: %s", e.message);
        }

        ulong cancel_id = 0;
        if (cancellable != null) {
            cancel_id = cancellable.connect (() => {
                oauth_error = "cancelled";
                loop.quit ();
            });
        }

        /* Re-enter the main loop until the browser redirect (or cancel). */
        loop.run ();

        if (cancellable != null && cancel_id != 0)
            cancellable.disconnect (cancel_id);

        try {
            server.disconnect ();
        } catch (Error e) {
        }

        if (oauth_error != null && oauth_error.length > 0) {
            throw new IdentityOAuthError.CANCELLED (_("Sign-in cancelled or denied (%s).").printf (oauth_error));
        }
        if (auth_code == null || auth_code.length == 0) {
            throw new IdentityOAuthError.TOKEN (_("No authorization code received."));
        }
        if (returned_state != state) {
            throw new IdentityOAuthError.STATE (_("OAuth state mismatch."));
        }

        return yield exchange_code (
            token_url, client_id, client_secret, auth_code, redirect, verifier, scope, cancellable
        );
    }

    private async IdentityOAuthTokens exchange_code (
        string token_url,
        string client_id,
        string? client_secret,
        string code,
        string redirect_uri,
        string verifier,
        string scope,
        Cancellable? cancellable
    ) throws Error {
        var body = new StringBuilder ();
        body.append_printf ("client_id=%s", Uri.escape_string (client_id));
        if (client_secret != null && client_secret.length > 0)
            body.append_printf ("&client_secret=%s", Uri.escape_string (client_secret));
        body.append ("&grant_type=authorization_code");
        body.append_printf ("&code=%s", Uri.escape_string (code));
        body.append_printf ("&redirect_uri=%s", Uri.escape_string (redirect_uri));
        body.append_printf ("&code_verifier=%s", Uri.escape_string (verifier));
        /* Microsoft v2 token endpoint requires scope on the code exchange. */
        if (scope.length > 0)
            body.append_printf ("&scope=%s", Uri.escape_string (scope));
        var msg = new Soup.Message.from_encoded_form ("POST", token_url, body.str);
        Bytes bytes;
        try {
            bytes = yield this.session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
        } catch (Error e) {
            throw new IdentityOAuthError.HTTP (_("Token request failed: %s").printf (e.message));
        }
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new IdentityOAuthError.TOKEN (
                _("Token endpoint HTTP %u: %s").printf (msg.status_code, bytes_to_string (bytes))
            );
        }
        return parse_token_json (bytes_to_string (bytes));
    }

    private async IdentityOAuthProfile fetch_google_profile (
        string access_token,
        Cancellable? cancellable
    ) throws Error {
        var msg = new Soup.Message ("GET", "https://www.googleapis.com/oauth2/v3/userinfo");
        msg.request_headers.append ("Authorization", "Bearer %s".printf (access_token));
        Bytes bytes;
        try {
            bytes = yield this.session.send_and_read_async (msg, Priority.DEFAULT, cancellable);
        } catch (Error e) {
            throw new IdentityOAuthError.HTTP (_("Google profile failed: %s").printf (e.message));
        }
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new IdentityOAuthError.TOKEN (
                _("Google profile HTTP %u").printf (msg.status_code)
            );
        }
        var parser = new Json.Parser ();
        parser.load_from_data (bytes_to_string (bytes));
        var obj = parser.get_root ().get_object ();
        var email = obj.get_string_member ("email");
        string? name = obj.has_member ("name") ? obj.get_string_member ("name") : null;
        return new IdentityOAuthProfile () {
            email = email,
            display_name = name,
        };
    }

    private static IdentityOAuthProfile profile_from_microsoft_id_token (string? id_token) throws Error {
        if (id_token == null || id_token.length == 0) {
            throw new IdentityOAuthError.TOKEN (_("Microsoft token response missing id_token."));
        }
        var parts = id_token.split (".");
        if (parts.length < 2) {
            throw new IdentityOAuthError.TOKEN (_("Microsoft id_token is malformed."));
        }
        var payload_b64 = parts[1].replace ("-", "+").replace ("_", "/");
        while (payload_b64.length % 4 != 0)
            payload_b64 += "=";
        uchar[] decoded;
        try {
            decoded = Base64.decode (payload_b64);
        } catch (Error e) {
            throw new IdentityOAuthError.TOKEN (_("Could not decode Microsoft id_token."));
        }
        var json_text = (string) decoded;
        var parser = new Json.Parser ();
        parser.load_from_data (json_text);
        var obj = parser.get_root ().get_object ();
        string? email = null;
        if (obj.has_member ("email") && obj.get_string_member ("email").length > 0)
            email = obj.get_string_member ("email");
        else if (obj.has_member ("preferred_username")
                 && obj.get_string_member ("preferred_username").length > 0)
            email = obj.get_string_member ("preferred_username");
        else if (obj.has_member ("upn") && obj.get_string_member ("upn").length > 0)
            email = obj.get_string_member ("upn");
        if (email == null || email.length == 0) {
            throw new IdentityOAuthError.TOKEN (_("Microsoft id_token has no email."));
        }
        string? name = obj.has_member ("name") ? obj.get_string_member ("name") : null;
        return new IdentityOAuthProfile () {
            email = email,
            display_name = name,
        };
    }

    public static IdentityOAuthTokens parse_token_json (string json_text) throws Error {
        var parser = new Json.Parser ();
        parser.load_from_data (json_text);
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new IdentityOAuthError.TOKEN (_("Invalid token JSON."));
        }
        var obj = root.get_object ();
        if (obj.has_member ("error")) {
            throw new IdentityOAuthError.TOKEN (
                _("Token error: %s").printf (obj.get_string_member ("error"))
            );
        }
        if (!obj.has_member ("access_token")) {
            throw new IdentityOAuthError.TOKEN (_("Token JSON missing access_token."));
        }
        int64 expires_in = obj.has_member ("expires_in")
            ? (int64) obj.get_int_member ("expires_in") : 3600;
        return new IdentityOAuthTokens () {
            access_token = obj.get_string_member ("access_token"),
            refresh_token = obj.has_member ("refresh_token")
                ? obj.get_string_member ("refresh_token") : null,
            id_token = obj.has_member ("id_token")
                ? obj.get_string_member ("id_token") : null,
            token_type = obj.has_member ("token_type")
                ? obj.get_string_member ("token_type") : null,
            expires_at = new DateTime.now_utc ().to_unix () + expires_in,
        };
    }

    private static string bytes_to_string (Bytes? bytes) {
        if (bytes == null)
            return "";
        size_t n = bytes.get_size ();
        if (n == 0)
            return "";
        unowned uint8[] data = bytes.get_data ();
        /* Soup Bytes are not NUL-terminated. Casting to string and letting
         * Json.Parser strlen() past the buffer → “JSON must be UTF-8”. */
        var copy = new uint8[n + 1];
        Memory.copy (copy, data, n);
        copy[n] = 0;
        return (string) copy;
    }

    /** Browser page after OAuth redirect — gettext so it follows the UI locale. */
    private static string oauth_success_html () {
        var title = Markup.escape_text (_("Signed in"));
        var heading = Markup.escape_text (_("Letter"));
        var message = Markup.escape_text (
            _("You can close this tab and return to Letter.")
        );
        /* Inline app icon (same mark as data/icons/…/Letter.svg). */
        const string ICON = """<svg xmlns="http://www.w3.org/2000/svg" width="72" height="72" viewBox="0 0 128 128" aria-hidden="true"><rect x="8" y="8" width="112" height="112" rx="24" fill="#1a5fb4"/><g transform="translate(8 8) scale(0.875)"><rect x="22" y="30" width="84" height="68" rx="8" fill="#f6f5f4"/><path d="M22 38.5 L64 68 L106 38.5" fill="none" stroke="#1a5fb4" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/><rect x="32" y="78" width="6" height="10" rx="1.5" fill="#9a9996"/><rect x="42" y="78" width="28" height="4" rx="2" fill="#9a9996"/><rect x="32" y="88" width="52" height="4" rx="2" fill="#c0bfbc"/></g></svg>""";
        return """<!DOCTYPE html>
<html lang="">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>%s — %s</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f6f5f4;
    --fg: #241f31;
    --muted: #5e5c64;
    --card: #ffffff;
    --accent: #1a5fb4;
    --shadow: 0 18px 48px rgba(26, 95, 180, 0.14);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1e1e1e;
      --fg: #eeeeec;
      --muted: #c0bfbc;
      --card: #2d2d2d;
      --shadow: 0 18px 48px rgba(0, 0, 0, 0.45);
    }
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    min-height: 100%%;
    font-family: "Cantarell", "Inter", system-ui, -apple-system, sans-serif;
    background:
      radial-gradient(1200px 600px at 50%% -10%%, color-mix(in srgb, var(--accent) 22%%, transparent), transparent 70%%),
      var(--bg);
    color: var(--fg);
  }
  body {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 32px 20px;
  }
  .card {
    width: min(420px, 100%%);
    text-align: center;
    background: var(--card);
    border-radius: 24px;
    padding: 40px 32px 36px;
    box-shadow: var(--shadow);
  }
  .icon { margin: 0 auto 20px; width: 72px; height: 72px; }
  .icon svg { display: block; width: 72px; height: 72px; }
  h1 {
    margin: 0 0 10px;
    font-size: 1.75rem;
    font-weight: 700;
    letter-spacing: -0.02em;
    color: var(--accent);
  }
  p {
    margin: 0;
    font-size: 1.05rem;
    line-height: 1.45;
    color: var(--muted);
  }
</style>
</head>
<body>
  <main class="card">
    <div class="icon">%s</div>
    <h1>%s</h1>
    <p>%s</p>
  </main>
</body>
</html>""".printf (heading, title, ICON, heading, message);
    }
}
