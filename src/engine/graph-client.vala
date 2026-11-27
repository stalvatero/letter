/**
 * Microsoft Graph mail REST client (no Camel / evolution-ews).
 * Sync helpers for worker threads (MainLoop + Soup async).
 */
public errordomain LetterGraph.ApiError {
    HTTP,
    JSON
}

public class LetterGraph.FolderInfo : Object {
    public string id { get; set; }
    public string display_name { get; set; }
    public string? parent_id { get; set; }
    public int64 total_item_count { get; set; }
    public int64 unread_item_count { get; set; }
    public int64 child_folder_count { get; set; }
    public string? well_known_name { get; set; }
}

public class LetterGraph.MessageHeader : Object {
    public string id { get; set; }
    public string? subject { get; set; }
    public string? from { get; set; }
    public string? to { get; set; }
    public string? received { get; set; }
    public bool seen { get; set; }
    public bool flagged { get; set; }
    public bool has_attachment { get; set; }
    public string? internet_message_id { get; set; }
    /** Outlook conversation thread id (same across Inbox/Sent/Archive). */
    public string? conversation_id { get; set; }
    /** Graph bodyPreview — short plain snippet for the message list. */
    public string? preview { get; set; }
}

public class LetterGraph.MessageBody : Object {
    public string id { get; set; }
    public string? subject { get; set; }
    public string? from { get; set; }
    public string? to { get; set; }
    public string? cc { get; set; }
    public string? received { get; set; }
    public string content_type { get; set; default = "text"; }
    public string content { get; set; default = ""; }
    public string? internet_message_id { get; set; }
    public string? conversation_id { get; set; }
}

/** Compose autocomplete row from Contacts / People / directory users. */
public class LetterGraph.PersonHit : Object {
    public string name { get; set; default = ""; }
    public string email { get; set; default = ""; }
}

public class LetterGraph.Client : Object {
    private Soup.Session session;
    private string access_token;

    public Client (string access_token) {
        this.access_token = access_token;
        this.session = new Soup.Session ();
        /* Large Archive pages can be slow; never hang forever with no log. */
        this.session.timeout = 90;
    }

    public void set_access_token (string token) {
        this.access_token = token;
    }

    public GenericArray<FolderInfo> list_mail_folders_sync (Cancellable? cancellable = null) throws GLib.Error {
        var list = new GenericArray<FolderInfo> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        string? url = "https://graph.microsoft.com/v1.0/me/mailFolders"
            + "?$top=100&$select=id,displayName,parentFolderId,totalItemCount,unreadItemCount,childFolderCount"
            + "&$expand=childFolders($select=id,displayName,parentFolderId,totalItemCount,unreadItemCount,childFolderCount;$top=100)";
        while (url != null) {
            var obj = get_json_sync (url, cancellable);
            if (obj.has_member ("value")) {
                foreach (var node in obj.get_array_member ("value").get_elements ()) {
                    append_folder_tree (list, seen, node.get_object (), null);
                }
            }
            url = obj.has_member ("@odata.nextLink")
                ? obj.get_string_member ("@odata.nextLink") : null;
        }

        /* Expand only returns one child level — pull deeper trees when needed. */
        for (uint i = 0; i < list.length; i++) {
            var info = list[i];
            if (info.child_folder_count <= 0)
                continue;
            uint have = 0;
            for (uint j = 0; j < list.length; j++) {
                if (list[j].parent_id == info.id)
                    have++;
            }
            if (have >= (uint) info.child_folder_count)
                continue;
            fetch_child_folders_sync (list, seen, info.id, cancellable);
        }
        return list;
    }

    /* Fresh totalItemCount / unreadItemCount for one folder (not FolderInfo). */
    public FolderInfo get_mail_folder_sync (
        string folder_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var url = ("https://graph.microsoft.com/v1.0/me/mailFolders/%s"
            + "?$select=id,displayName,parentFolderId,totalItemCount,unreadItemCount,childFolderCount")
            .printf (Uri.escape_string (folder_id, null, false));
        var obj = get_json_sync (url, cancellable);
        return folder_from_object (obj, null);
    }

    /**
     * Merge Contacts + People + directory users for compose autocomplete.
     * Soft-fails individual sources (403 / no admin consent on GAL).
     */
    public GenericArray<PersonHit> search_people_for_compose_sync (
        string query,
        uint top = 12,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var hits = new GenericArray<PersonHit> ();
        var seen = new HashTable<string, uint8> (str_hash, str_equal);
        var q = query.strip ();
        if (q.length == 0)
            return hits;
        var limit = top > 0 ? top : 12;

        try {
            append_unique_people (hits, seen, search_contacts_sync (q, limit, cancellable));
        } catch (Error e) {
            debug ("Graph contacts search: %s", e.message);
        }
        try {
            append_unique_people (hits, seen, search_people_api_sync (q, limit, cancellable));
        } catch (Error e) {
            debug ("Graph people search: %s", e.message);
        }
        try {
            append_unique_people (hits, seen, search_users_sync (q, limit, cancellable));
        } catch (Error e) {
            debug ("Graph users/GAL search: %s", e.message);
        }
        return hits;
    }

    public GenericArray<PersonHit> search_contacts_sync (
        string query,
        uint top = 12,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var hits = new GenericArray<PersonHit> ();
        var raw = query.strip ();
        if (raw.length == 0)
            return hits;
        var limit = top > 0 ? top : 12;
        /* Prefer $search (name + addresses). startswith(displayName) misses
         * contacts whose display name does not begin with the needle. */
        Json.Object? obj = null;
        try {
            var search_url = ("https://graph.microsoft.com/v1.0/me/contacts"
                + "?$top=%u&$select=displayName,emailAddresses&$search=\"%s\"")
                .printf (limit, Uri.escape_string (raw, null, false));
            obj = get_json_sync_eventual (search_url, cancellable);
        } catch (Error e) {
            debug ("Graph contacts $search: %s", e.message);
            var q = escape_odata_string (raw);
            var url = ("https://graph.microsoft.com/v1.0/me/contacts"
                + "?$top=%u&$select=displayName,emailAddresses"
                + "&$filter=startswith(displayName,'%s')")
                .printf (limit, q);
            obj = get_json_sync (url, cancellable);
        }
        if (obj == null || !obj.has_member ("value"))
            return hits;
        foreach (var node in obj.get_array_member ("value").get_elements ())
            append_contact_emails (hits, node.get_object ());
        return hits;
    }

    public GenericArray<PersonHit> search_people_api_sync (
        string query,
        uint top = 12,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var hits = new GenericArray<PersonHit> ();
        var q = query.strip ();
        if (q.length == 0)
            return hits;
        var url = ("https://graph.microsoft.com/v1.0/me/people"
            + "?$top=%u&$select=displayName,scoredEmailAddresses"
            + "&$search=\"%s\"")
            .printf (
                top > 0 ? top : 12,
                Uri.escape_string (q, null, false)
            );
        var obj = get_json_sync_eventual (url, cancellable);
        if (!obj.has_member ("value"))
            return hits;
        foreach (var node in obj.get_array_member ("value").get_elements ()) {
            var o = node.get_object ();
            var name = string_member_or_null (o, "displayName") ?? "";
            if (!o.has_member ("scoredEmailAddresses")
                || o.get_member ("scoredEmailAddresses") == null
                || o.get_member ("scoredEmailAddresses").is_null ())
                continue;
            foreach (var en in o.get_array_member ("scoredEmailAddresses").get_elements ()) {
                var eo = en.get_object ();
                var addr = string_member_or_null (eo, "address");
                if (addr == null || addr.index_of_char ('@') <= 0)
                    continue;
                hits.add (new PersonHit () {
                    name = name,
                    email = addr,
                });
            }
        }
        return hits;
    }

    public GenericArray<PersonHit> search_users_sync (
        string query,
        uint top = 12,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var hits = new GenericArray<PersonHit> ();
        var q = query.strip ();
        if (q.length == 0)
            return hits;
        var search = "displayName:%s OR mail:%s OR userPrincipalName:%s".printf (q, q, q);
        var url = ("https://graph.microsoft.com/v1.0/users"
            + "?$top=%u&$select=displayName,mail,userPrincipalName,givenName,surname"
            + "&$search=%s")
            .printf (
                top > 0 ? top : 12,
                Uri.escape_string ("\"%s\"".printf (search), null, false)
            );
        Json.Object obj;
        try {
            obj = get_json_sync_eventual (url, cancellable);
        } catch (Error e) {
            var odata = escape_odata_string (q);
            var filter_url = ("https://graph.microsoft.com/v1.0/users"
                + "?$top=%u&$select=displayName,mail,userPrincipalName"
                + "&$filter=startswith(displayName,'%s') or startswith(mail,'%s') or startswith(userPrincipalName,'%s')")
                .printf (top > 0 ? top : 12, odata, odata, odata);
            obj = get_json_sync (filter_url, cancellable);
        }
        if (!obj.has_member ("value"))
            return hits;
        foreach (var node in obj.get_array_member ("value").get_elements ()) {
            var o = node.get_object ();
            var name = string_member_or_null (o, "displayName") ?? "";
            var mail = string_member_or_null (o, "mail");
            if (mail == null || mail.index_of_char ('@') <= 0)
                mail = string_member_or_null (o, "userPrincipalName");
            if (mail == null || mail.index_of_char ('@') <= 0)
                continue;
            hits.add (new PersonHit () {
                name = name,
                email = mail,
            });
        }
        return hits;
    }

    /* Raw RFC822 MIME for Save as EML. */
    public Bytes fetch_message_mime_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var url = "https://graph.microsoft.com/v1.0/me/messages/%s/$value".printf (
            Uri.escape_string (message_id, null, false)
        );
        var msg = new Soup.Message ("GET", url);
        msg.request_headers.append ("Authorization", "Bearer " + this.access_token);
        msg.request_headers.append ("Accept", "message/rfc822, application/octet-stream, */*");

        Bytes? bytes = null;
        Error? err = null;
        var loop = new MainLoop ();
        this.session.send_and_read_async.begin (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            try {
                bytes = this.session.send_and_read_async.end (res);
            } catch (Error e) {
                err = e;
            }
            loop.quit ();
        });
        loop.run ();
        if (err != null)
            throw new ApiError.HTTP ("Graph MIME GET failed: %s".printf (err.message));
        if (bytes == null || bytes.get_size () == 0)
            throw new ApiError.HTTP ("Graph MIME GET returned empty body");
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new ApiError.HTTP (
                "Graph MIME HTTP %u: %s".printf (
                    msg.status_code,
                    bytes_to_utf8 (bytes.get_data ())
                )
            );
        }
        return bytes;
    }

    private static void append_unique_people (
        GenericArray<PersonHit> dest,
        HashTable<string, uint8> seen,
        GenericArray<PersonHit> src
    ) {
        for (uint i = 0; i < src.length; i++) {
            var email = src[i].email.strip ().down ();
            if (email.length == 0 || seen.contains (email))
                continue;
            seen.set (email, 1);
            dest.add (src[i]);
        }
    }

    /**
     * All mailbox addresses from /me/contacts (paginated). Used to exclude
     * address-book hits from the “recent addresses” collected list.
     */
    public void collect_contact_emails_sync (
        HashTable<string, uint8> into,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        string? url = "https://graph.microsoft.com/v1.0/me/contacts"
            + "?$top=100&$select=emailAddresses";
        while (url != null) {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("cancelled");
            var obj = get_json_sync (url, cancellable);
            if (obj.has_member ("value")) {
                foreach (var node in obj.get_array_member ("value").get_elements ()) {
                    var o = node.get_object ();
                    if (!o.has_member ("emailAddresses")
                        || o.get_member ("emailAddresses") == null
                        || o.get_member ("emailAddresses").is_null ())
                        continue;
                    foreach (var en in o.get_array_member ("emailAddresses").get_elements ()) {
                        var eo = en.get_object ();
                        var addr = string_member_or_null (eo, "address");
                        if (addr == null || addr.index_of_char ('@') <= 0)
                            continue;
                        var key = addr.strip ().down ();
                        if (key.length > 0)
                            into.set (key, 1);
                    }
                }
            }
            url = obj.has_member ("@odata.nextLink")
                ? obj.get_string_member ("@odata.nextLink") : null;
        }
    }

    /**
     * Org directory (GAL) via /users — mail + UPN. Needs User.ReadBasic.All
     * (admin consent). Used with contacts to prune collected “recent” rows.
     */
    public void collect_gal_emails_sync (
        HashTable<string, uint8> into,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        string? url = "https://graph.microsoft.com/v1.0/users"
            + "?$top=100&$select=mail,userPrincipalName";
        while (url != null) {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("cancelled");
            var obj = get_json_sync (url, cancellable);
            if (obj.has_member ("value")) {
                foreach (var node in obj.get_array_member ("value").get_elements ()) {
                    var o = node.get_object ();
                    add_directory_email (into, string_member_or_null (o, "mail"));
                    add_directory_email (into, string_member_or_null (o, "userPrincipalName"));
                }
            }
            url = obj.has_member ("@odata.nextLink")
                ? obj.get_string_member ("@odata.nextLink") : null;
        }
    }

    private static void add_directory_email (HashTable<string, uint8> into, string? raw) {
        if (raw == null || raw.length == 0)
            return;
        var key = raw.strip ().down ();
        if (key.index_of_char ('@') <= 0)
            return;
        /* Skip typical guest UPN noise without a usable SMTP mailbox. */
        if (key.contains ("#ext#"))
            return;
        into.set (key, 1);
    }

    private static void append_contact_emails (
        GenericArray<PersonHit> hits,
        Json.Object o
    ) {
        var name = string_member_or_null (o, "displayName") ?? "";
        if (!o.has_member ("emailAddresses")
            || o.get_member ("emailAddresses") == null
            || o.get_member ("emailAddresses").is_null ())
            return;
        foreach (var en in o.get_array_member ("emailAddresses").get_elements ()) {
            var eo = en.get_object ();
            var addr = string_member_or_null (eo, "address");
            if (addr == null || addr.index_of_char ('@') <= 0)
                continue;
            hits.add (new PersonHit () {
                name = name,
                email = addr,
            });
        }
    }

    private static string escape_odata_string (string raw) {
        return raw.replace ("'", "''");
    }

    private void fetch_child_folders_sync (
        GenericArray<FolderInfo> list,
        HashTable<string, uint8> seen,
        string parent_id,
        Cancellable? cancellable
    ) throws GLib.Error {
        string? url = "https://graph.microsoft.com/v1.0/me/mailFolders/%s/childFolders?$top=100&$select=id,displayName,parentFolderId,totalItemCount,unreadItemCount,childFolderCount"
            .printf (Uri.escape_string (parent_id, null, false));
        while (url != null) {
            var obj = get_json_sync (url, cancellable);
            if (obj.has_member ("value")) {
                foreach (var node in obj.get_array_member ("value").get_elements ()) {
                    append_folder_tree (list, seen, node.get_object (), parent_id);
                }
            }
            url = obj.has_member ("@odata.nextLink")
                ? obj.get_string_member ("@odata.nextLink") : null;
        }
    }

    private static void append_folder_tree (
        GenericArray<FolderInfo> list,
        HashTable<string, uint8> seen,
        Json.Object o,
        string? parent_override
    ) {
        var info = folder_from_object (o, parent_override);
        if (!seen.contains (info.id)) {
            seen.set (info.id, 1);
            list.add (info);
        }
        if (!o.has_member ("childFolders"))
            return;
        var children = o.get_member ("childFolders");
        if (children == null || children.is_null ())
            return;
        if (children.get_node_type () != Json.NodeType.ARRAY)
            return;
        foreach (var node in children.get_array ().get_elements ()) {
            append_folder_tree (list, seen, node.get_object (), info.id);
        }
    }

    private static FolderInfo folder_from_object (Json.Object o, string? parent_override) {
        string? parent = parent_override;
        if (parent == null && o.has_member ("parentFolderId")
            && o.get_member ("parentFolderId") != null
            && !o.get_member ("parentFolderId").is_null ())
            parent = o.get_string_member ("parentFolderId");
        return new FolderInfo () {
            id = o.get_string_member ("id"),
            display_name = o.has_member ("displayName")
                ? o.get_string_member ("displayName") : _("Folder"),
            parent_id = parent,
            total_item_count = o.has_member ("totalItemCount")
                ? o.get_int_member ("totalItemCount") : 0,
            unread_item_count = o.has_member ("unreadItemCount")
                ? o.get_int_member ("unreadItemCount") : 0,
            child_folder_count = o.has_member ("childFolderCount")
                ? o.get_int_member ("childFolderCount") : 0,
        };
    }

    /**
     * @param max_pages 1 = tip (newest page only); higher follows @odata.nextLink
     * @param more true if Graph still has a next page after stopping
     * @param resume_url @odata.nextLink from a prior chunk (null = folder head)
     * @param next_url nextLink to resume later when @more is true
     */
    public GenericArray<MessageHeader> list_folder_headers_sync (
        string folder_id,
        uint top = 50,
        uint max_pages = 1,
        out bool more = null,
        string? resume_url = null,
        out string? next_url = null,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        more = false;
        next_url = null;
        if (max_pages == 0)
            max_pages = 1;
        var list = new GenericArray<MessageHeader> ();
        string? url = resume_url;
        if (url == null || url.length == 0) {
            url = "https://graph.microsoft.com/v1.0/me/mailFolders/%s/messages?$top=%u&$orderby=receivedDateTime%%20desc&$select=id,subject,from,toRecipients,receivedDateTime,isRead,flag,hasAttachments,internetMessageId,conversationId,bodyPreview"
                .printf (Uri.escape_string (folder_id, null, false), top);
        }
        uint pages = 0;
        while (url != null && pages < max_pages) {
            if (cancellable != null && cancellable.is_cancelled ()) {
                more = true;
                next_url = url;
                break;
            }
            var obj = get_json_sync (url, cancellable);
            pages++;
            if (obj.has_member ("value")) {
                foreach (var node in obj.get_array_member ("value").get_elements ())
                    list.add (header_from_object (node.get_object ()));
            }
            if (obj.has_member ("@odata.nextLink")) {
                url = obj.get_string_member ("@odata.nextLink");
                more = true;
                next_url = url;
            } else {
                url = null;
                more = false;
                next_url = null;
            }
        }
        if (url == null) {
            more = false;
            next_url = null;
        }
        return list;
    }

    private static MessageHeader header_from_object (Json.Object o) {
        bool flagged = false;
        if (o.has_member ("flag") && o.get_member ("flag") != null
            && !o.get_member ("flag").is_null ()) {
            var flag = o.get_object_member ("flag");
            if (flag.has_member ("flagStatus")) {
                var st = flag.get_string_member ("flagStatus") ?? "";
                flagged = st.down () == "flagged";
            }
        }
        return new MessageHeader () {
            id = o.get_string_member ("id"),
            subject = string_member_or_null (o, "subject"),
            from = format_recipient (o, "from"),
            to = format_recipients_array (o, "toRecipients"),
            received = string_member_or_null (o, "receivedDateTime"),
            seen = o.has_member ("isRead") && o.get_boolean_member ("isRead"),
            flagged = flagged,
            has_attachment = o.has_member ("hasAttachments")
                && o.get_boolean_member ("hasAttachments"),
            internet_message_id = string_member_or_null (o, "internetMessageId"),
            conversation_id = string_member_or_null (o, "conversationId"),
            preview = string_member_or_null (o, "bodyPreview"),
        };
    }

    public void set_message_read_sync (
        string message_id,
        bool seen,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var body = "{\"isRead\":%s}".printf (seen ? "true" : "false");
        patch_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s".printf (
                Uri.escape_string (message_id, null, false)
            ),
            body,
            cancellable
        );
    }

    public void set_message_flagged_sync (
        string message_id,
        bool flagged,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var status = flagged ? "flagged" : "notFlagged";
        var body = "{\"flag\":{\"flagStatus\":\"%s\"}}".printf (status);
        patch_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s".printf (
                Uri.escape_string (message_id, null, false)
            ),
            body,
            cancellable
        );
    }

    public void move_message_sync (
        string message_id,
        string destination_folder_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var body = "{\"destinationId\":\"%s\"}".printf (
            escape_json_string (destination_folder_id)
        );
        post_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s/move".printf (
                Uri.escape_string (message_id, null, false)
            ),
            body,
            cancellable
        );
    }

    public void copy_message_sync (
        string message_id,
        string destination_folder_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var body = "{\"destinationId\":\"%s\"}".printf (
            escape_json_string (destination_folder_id)
        );
        post_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s/copy".printf (
                Uri.escape_string (message_id, null, false)
            ),
            body,
            cancellable
        );
    }

    /** All message ids in a folder (paged). Used by Empty Folder. */
    public GenericArray<string> list_folder_message_ids_sync (
        string folder_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var ids = new GenericArray<string> ();
        string? url = "https://graph.microsoft.com/v1.0/me/mailFolders/%s/messages?$select=id&$top=100"
            .printf (Uri.escape_string (folder_id, null, false));
        while (url != null) {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Cancelled");
            var obj = get_json_sync (url, cancellable);
            if (obj.has_member ("value")) {
                foreach (var node in obj.get_array_member ("value").get_elements ()) {
                    var o = node.get_object ();
                    if (o.has_member ("id")) {
                        var id = o.get_string_member ("id");
                        if (id != null && id.length > 0)
                            ids.add (id);
                    }
                }
            }
            url = obj.has_member ("@odata.nextLink")
                ? obj.get_string_member ("@odata.nextLink") : null;
        }
        return ids;
    }

    public void permanent_delete_message_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        request_json_sync (
            "POST",
            "https://graph.microsoft.com/v1.0/me/messages/%s/permanentDelete".printf (
                Uri.escape_string (message_id, null, false)
            ),
            null,
            cancellable
        );
    }

    public void delete_message_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        request_json_sync (
            "DELETE",
            "https://graph.microsoft.com/v1.0/me/messages/%s".printf (
                Uri.escape_string (message_id, null, false)
            ),
            null,
            cancellable
        );
    }

    /** POST /me/sendMail — 202 Accepted, empty body. */
    public void send_mail_sync (string json_body, Cancellable? cancellable = null) throws GLib.Error {
        request_json_sync (
            "POST",
            "https://graph.microsoft.com/v1.0/me/sendMail",
            json_body,
            cancellable
        );
    }

    public void reply_message_sync (
        string message_id,
        string json_body,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        request_json_sync (
            "POST",
            "https://graph.microsoft.com/v1.0/me/messages/%s/reply".printf (
                Uri.escape_string (message_id, null, false)
            ),
            json_body,
            cancellable
        );
    }

    public void forward_message_sync (
        string message_id,
        string json_body,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        request_json_sync (
            "POST",
            "https://graph.microsoft.com/v1.0/me/messages/%s/forward".printf (
                Uri.escape_string (message_id, null, false)
            ),
            json_body,
            cancellable
        );
    }

    /** POST /me/messages → draft; returns Graph message id. */
    public string create_draft_sync (
        string json_body,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var obj = post_json_object_sync (
            "https://graph.microsoft.com/v1.0/me/messages",
            json_body,
            cancellable
        );
        if (!obj.has_member ("id"))
            throw new ApiError.JSON ("Graph create draft: missing id");
        var id = obj.get_string_member ("id");
        if (id == null || id.length == 0)
            throw new ApiError.JSON ("Graph create draft: empty id");
        return id;
    }

    public void update_message_sync (
        string message_id,
        string json_body,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        patch_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s".printf (
                Uri.escape_string (message_id, null, false)
            ),
            json_body,
            cancellable
        );
    }

    public static string escape_json_string (string s) {
        return s.replace ("\\", "\\\\").replace ("\"", "\\\"").replace ("\n", "\\n")
            .replace ("\r", "\\r").replace ("\t", "\\t");
    }

    public MessageBody fetch_message_body_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var path = "/v1.0/me/messages/%s?$select=id,subject,from,toRecipients,ccRecipients,receivedDateTime,body,internetMessageId,conversationId"
            .printf (Uri.escape_string (message_id, null, false));
        var o = get_json_sync ("https://graph.microsoft.com" + path, cancellable);
        string content_type = "text";
        string content = "";
        if (o.has_member ("body") && o.get_member ("body") != null
            && !o.get_member ("body").is_null ()) {
            var body = o.get_object_member ("body");
            if (body.has_member ("contentType"))
                content_type = body.get_string_member ("contentType") ?? "text";
            if (body.has_member ("content"))
                content = body.get_string_member ("content") ?? "";
        }
        return new MessageBody () {
            id = o.get_string_member ("id"),
            subject = string_member_or_null (o, "subject"),
            from = format_recipient (o, "from"),
            to = format_recipients_array (o, "toRecipients"),
            cc = format_recipients_array (o, "ccRecipients"),
            received = string_member_or_null (o, "receivedDateTime"),
            content_type = content_type,
            content = content,
            internet_message_id = string_member_or_null (o, "internetMessageId"),
            conversation_id = string_member_or_null (o, "conversationId"),
        };
    }

    /** Draft in the same Outlook conversation as @message_id (preserves conversationId). */
    public string create_forward_draft_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        return create_reply_like_draft_sync (message_id, "createForward", cancellable);
    }

    public string create_reply_draft_sync (
        string message_id,
        bool reply_all,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        return create_reply_like_draft_sync (
            message_id,
            reply_all ? "createReplyAll" : "createReply",
            cancellable
        );
    }

    private string create_reply_like_draft_sync (
        string message_id,
        string action,
        Cancellable? cancellable
    ) throws GLib.Error {
        var url = "https://graph.microsoft.com/v1.0/me/messages/%s/%s".printf (
            Uri.escape_string (message_id, null, false),
            action
        );
        var obj = post_json_object_sync (url, "{}", cancellable);
        if (!obj.has_member ("id"))
            throw new ApiError.JSON ("Graph %s: missing id".printf (action));
        var id = obj.get_string_member ("id");
        if (id == null || id.length == 0)
            throw new ApiError.JSON ("Graph %s: empty id".printf (action));
        return id;
    }

    public void send_draft_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        post_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s/send".printf (
                Uri.escape_string (message_id, null, false)
            ),
            "",
            cancellable
        );
    }

    public uint count_message_attachments_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        var url = ("https://graph.microsoft.com/v1.0/me/messages/%s/attachments"
            + "?$select=id&$top=50").printf (
            Uri.escape_string (message_id, null, false)
        );
        var obj = get_json_sync (url, cancellable);
        if (!obj.has_member ("value"))
            return 0;
        return obj.get_array_member ("value").get_length ();
    }

    /**
     * createForward attaches the original as an Outlook itemAttachment; that
     * MIME often NDRs to external recipients. Strip every attachment (item +
     * file) before we PATCH Letter's quoted HTML and optional file attachments.
     */
    public void clear_message_attachments_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        /* A few passes — Graph may page; createForward usually has one item. */
        for (int pass = 0; pass < 5; pass++) {
            var url = ("https://graph.microsoft.com/v1.0/me/messages/%s/attachments"
                + "?$select=id&$top=50").printf (
                Uri.escape_string (message_id, null, false)
            );
            var obj = get_json_sync (url, cancellable);
            if (!obj.has_member ("value"))
                return;
            var arr = obj.get_array_member ("value");
            if (arr.get_length () == 0)
                return;
            foreach (var node in arr.get_elements ()) {
                var o = node.get_object ();
                if (!o.has_member ("id"))
                    continue;
                var att_id = o.get_string_member ("id");
                if (att_id == null || att_id.length == 0)
                    continue;
                request_json_sync (
                    "DELETE",
                    "https://graph.microsoft.com/v1.0/me/messages/%s/attachments/%s".printf (
                        Uri.escape_string (message_id, null, false),
                        Uri.escape_string (att_id, null, false)
                    ),
                    null,
                    cancellable
                );
            }
        }
    }

    public void add_file_attachment_sync (
        string message_id,
        string filename,
        string mime_type,
        Bytes data,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        unowned uint8[] raw = data.get_data ();
        var body = ("{\"@odata.type\":\"#microsoft.graph.fileAttachment\","
            + "\"name\":\"%s\",\"contentType\":\"%s\",\"contentBytes\":\"%s\"}").printf (
            escape_json_string (filename),
            escape_json_string (mime_type),
            Base64.encode (raw)
        );
        post_json_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s/attachments".printf (
                Uri.escape_string (message_id, null, false)
            ),
            body,
            cancellable
        );
    }

    /* Graph inline fileAttachment contentBytes max is 3 MiB; larger files need
     * createUploadSession + chunked PUT to the returned uploadUrl. */
    public const size_t INLINE_ATTACHMENT_MAX = 3 * 1024 * 1024;
    private const size_t UPLOAD_CHUNK_SIZE = 4 * 1024 * 1024;

    public void add_file_attachment_upload_session_sync (
        string message_id,
        string filename,
        string mime_type,
        Bytes data,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        unowned uint8[] raw = data.get_data ();
        if (raw.length == 0)
            return;
        var meta = ("{\"AttachmentItem\":{"
            + "\"attachmentType\":\"file\","
            + "\"name\":\"%s\","
            + "\"size\":%d,"
            + "\"contentType\":\"%s\"}}").printf (
            escape_json_string (filename),
            raw.length,
            escape_json_string (mime_type)
        );
        var created = post_json_object_sync (
            "https://graph.microsoft.com/v1.0/me/messages/%s/attachments/createUploadSession".printf (
                Uri.escape_string (message_id, null, false)
            ),
            meta,
            cancellable
        );
        var upload_url = string_member_or_null (created, "uploadUrl");
        if (upload_url == null || upload_url.length == 0)
            throw new ApiError.JSON ("Graph createUploadSession missing uploadUrl");

        size_t offset = 0;
        while (offset < (size_t) raw.length) {
            if (cancellable != null && cancellable.is_cancelled ())
                throw new IOError.CANCELLED ("Cancelled");
            var end = size_t.min (offset + UPLOAD_CHUNK_SIZE, (size_t) raw.length);
            var slice = data.slice ((int) offset, (int) end);
            put_upload_chunk_sync (
                upload_url,
                slice,
                offset,
                end - 1,
                (size_t) raw.length,
                cancellable
            );
            offset = end;
        }
    }

    private void put_upload_chunk_sync (
        string upload_url,
        Bytes chunk,
        size_t start,
        size_t end_inclusive,
        size_t total,
        Cancellable? cancellable
    ) throws GLib.Error {
        var msg = new Soup.Message ("PUT", upload_url);
        /* uploadUrl is pre-authenticated — do not send Bearer. */
        msg.request_headers.append (
            "Content-Range",
            "bytes %llu-%llu/%llu".printf (
                (uint64) start,
                (uint64) end_inclusive,
                (uint64) total
            )
        );
        msg.set_request_body_from_bytes ("application/octet-stream", chunk);
        Bytes? bytes = null;
        Error? err = null;
        var loop = new MainLoop ();
        this.session.send_and_read_async.begin (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            try {
                bytes = this.session.send_and_read_async.end (res);
            } catch (Error e) {
                err = e;
            }
            loop.quit ();
        });
        loop.run ();
        if (err != null)
            throw new ApiError.HTTP ("Graph upload PUT failed: %s".printf (err.message));
        /* 200 = final, 201 = created, 202 = more chunks expected. */
        if (msg.status_code < 200 || msg.status_code >= 300) {
            string detail = "";
            if (bytes != null)
                detail = bytes_to_utf8 (bytes.get_data ());
            throw new ApiError.HTTP (
                "Graph upload PUT HTTP %u: %s".printf (msg.status_code, detail)
            );
        }
    }

    /**
     * Split Graph attachments into reader chips vs cid: inline images.
     * List query cannot $select contentId (fileAttachment-only → 400); a
     * per-id GET fills contentId. Bytes always come from /$value.
     */
    public void fetch_message_parts_sync (
        string message_id,
        out GenericArray<Mail.Attachment> file_attachments,
        out GenericArray<Mail.InlineImage> inline_images,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        file_attachments = new GenericArray<Mail.Attachment> ();
        inline_images = new GenericArray<Mail.InlineImage> ();
        var url = ("https://graph.microsoft.com/v1.0/me/messages/%s/attachments"
            + "?$select=id,name,contentType,size,isInline&$top=50").printf (
            Uri.escape_string (message_id, null, false)
        );
        var obj = get_json_sync (url, cancellable);
        if (!obj.has_member ("value"))
            return;
        foreach (var node in obj.get_array_member ("value").get_elements ()) {
            var o = node.get_object ();
            var odata_type = string_member_or_null (o, "@odata.type") ?? "";
            var is_inline = o.has_member ("isInline") && o.get_boolean_member ("isInline");
            var att_id = string_member_or_null (o, "id");
            var name = string_member_or_null (o, "name") ?? "";
            var mime = string_member_or_null (o, "contentType") ?? "application/octet-stream";
            int64 size = o.has_member ("size") ? o.get_int_member ("size") : 0;
            if (att_id == null || att_id.length == 0)
                continue;
            /* referenceAttachment / itemAttachment have no /$value file bytes. */
            var is_file = odata_type.contains ("fileAttachment")
                || (!odata_type.contains ("itemAttachment")
                    && !odata_type.contains ("referenceAttachment")
                    && !mime.has_prefix ("message/"));
            if (!is_file)
                continue;

            string? content_id = null;
            try {
                content_id = fetch_attachment_content_id_sync (message_id, att_id, cancellable);
            } catch (Error e) {
                warning ("Graph attachment meta “%s”: %s", name, e.message);
            }

            Bytes data = new Bytes ({});
            try {
                data = fetch_attachment_bytes_sync (message_id, att_id, cancellable);
            } catch (Error e) {
                warning ("Graph attachment $value “%s”: %s", name.length > 0 ? name : att_id, e.message);
            }

            var want_inline = is_inline
                || (content_id != null && content_id.length > 0
                    && mime.has_prefix ("image/"));
            if (want_inline && content_id != null && content_id.length > 0
                && data.get_size () > 0) {
                inline_images.add (new Mail.InlineImage () {
                    cid = strip_content_id (content_id),
                    mime_type = mime,
                    data = data,
                });
                continue;
            }

            if (name.length == 0)
                name = "attachment";
            file_attachments.add (new Mail.Attachment () {
                filename = name,
                mime_type = mime,
                data = data,
                size_bytes = size > 0 ? size : (int64) data.get_size (),
                content_id = content_id,
                inline_part = is_inline,
            });
        }
    }

    /** Chip-only convenience (no cid split) — prefer fetch_message_parts_sync. */
    public GenericArray<Mail.Attachment> fetch_message_attachments_sync (
        string message_id,
        Cancellable? cancellable = null
    ) throws GLib.Error {
        GenericArray<Mail.Attachment> files;
        GenericArray<Mail.InlineImage> inlines;
        fetch_message_parts_sync (message_id, out files, out inlines, cancellable);
        return files;
    }

    private string? fetch_attachment_content_id_sync (
        string message_id,
        string attachment_id,
        Cancellable? cancellable
    ) throws GLib.Error {
        var url = "https://graph.microsoft.com/v1.0/me/messages/%s/attachments/%s".printf (
            Uri.escape_string (message_id, null, false),
            Uri.escape_string (attachment_id, null, false)
        );
        var o = get_json_sync (url, cancellable);
        return strip_content_id (string_member_or_null (o, "contentId"));
    }

    private static string strip_content_id (string? cid) {
        if (cid == null || cid.length == 0)
            return "";
        var builder = new StringBuilder ();
        for (int i = 0; i < cid.length; i++) {
            var ch = cid[i];
            if (ch == '<' || ch == '>')
                continue;
            builder.append_c (ch);
        }
        return builder.str.strip ();
    }

    private Bytes fetch_attachment_bytes_sync (
        string message_id,
        string attachment_id,
        Cancellable? cancellable
    ) throws GLib.Error {
        var url = "https://graph.microsoft.com/v1.0/me/messages/%s/attachments/%s/$value".printf (
            Uri.escape_string (message_id, null, false),
            Uri.escape_string (attachment_id, null, false)
        );
        var msg = new Soup.Message ("GET", url);
        msg.request_headers.append ("Authorization", "Bearer " + this.access_token);
        msg.request_headers.append ("Accept", "*/*");
        Bytes? bytes = null;
        Error? err = null;
        var loop = new MainLoop ();
        this.session.send_and_read_async.begin (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            try {
                bytes = this.session.send_and_read_async.end (res);
            } catch (Error e) {
                err = e;
            }
            loop.quit ();
        });
        loop.run ();
        if (err != null)
            throw new ApiError.HTTP ("Graph attachment GET failed: %s".printf (err.message));
        if (msg.status_code < 200 || msg.status_code >= 300) {
            string detail = bytes != null ? bytes_to_utf8 (bytes.get_data ()) : "";
            throw new ApiError.HTTP (
                "Graph attachment HTTP %u: %s".printf (msg.status_code, detail)
            );
        }
        return bytes ?? new Bytes ({});
    }

    private void patch_json_sync (
        string url,
        string json_body,
        Cancellable? cancellable
    ) throws GLib.Error {
        request_json_sync ("PATCH", url, json_body, cancellable);
    }

    private void post_json_sync (
        string url,
        string json_body,
        Cancellable? cancellable
    ) throws GLib.Error {
        request_json_sync ("POST", url, json_body, cancellable);
    }

    private Json.Object post_json_object_sync (
        string url,
        string json_body,
        Cancellable? cancellable
    ) throws GLib.Error {
        var bytes = request_json_bytes_sync ("POST", url, json_body, cancellable);
        if (bytes == null)
            throw new ApiError.HTTP ("Graph POST returned empty body");
        unowned uint8[] data = bytes.get_data ();
        var parser = new Json.Parser ();
        try {
            parser.load_from_data ((string) data, data.length);
        } catch (Error e) {
            throw new ApiError.JSON ("Graph JSON: %s".printf (e.message));
        }
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
            throw new ApiError.JSON ("Graph response is not a JSON object");
        return root.get_object ();
    }

    private void request_json_sync (
        string method,
        string url,
        string? json_body,
        Cancellable? cancellable
    ) throws GLib.Error {
        request_json_bytes_sync (method, url, json_body, cancellable);
    }

    private Bytes? request_json_bytes_sync (
        string method,
        string url,
        string? json_body,
        Cancellable? cancellable
    ) throws GLib.Error {
        var msg = new Soup.Message (method, url);
        msg.request_headers.append ("Authorization", "Bearer " + this.access_token);
        msg.request_headers.append ("Accept", "application/json");
        if (json_body != null) {
            msg.set_request_body_from_bytes (
                "application/json",
                new Bytes (json_body.data)
            );
        }
        Bytes? bytes = null;
        Error? err = null;
        var loop = new MainLoop ();
        this.session.send_and_read_async.begin (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            try {
                bytes = this.session.send_and_read_async.end (res);
            } catch (Error e) {
                err = e;
            }
            loop.quit ();
        });
        loop.run ();
        if (err != null)
            throw new ApiError.HTTP ("Graph %s failed: %s".printf (method, err.message));
        /* 202 Accepted (sendMail) and 204 No Content (delete) are success. */
        if (msg.status_code < 200 || msg.status_code >= 300) {
            string detail = "";
            if (bytes != null)
                detail = bytes_to_utf8 (bytes.get_data ());
            throw new ApiError.HTTP (
                "Graph %s HTTP %u: %s".printf (method, msg.status_code, detail)
            );
        }
        return bytes;
    }

    private Json.Object get_json_sync (string url, Cancellable? cancellable) throws GLib.Error {
        return get_json_sync_full (url, false, cancellable);
    }

    /* People / users $search require ConsistencyLevel: eventual. */
    private Json.Object get_json_sync_eventual (string url, Cancellable? cancellable) throws GLib.Error {
        return get_json_sync_full (url, true, cancellable);
    }

    private Json.Object get_json_sync_full (
        string url,
        bool eventual,
        Cancellable? cancellable
    ) throws GLib.Error {
        var msg = new Soup.Message ("GET", url);
        msg.request_headers.append ("Authorization", "Bearer " + this.access_token);
        msg.request_headers.append ("Accept", "application/json");
        if (eventual)
            msg.request_headers.append ("ConsistencyLevel", "eventual");

        Bytes? bytes = null;
        Error? err = null;
        /* Shared Soup.Session + worker threads: use the default MainLoop so
         * callbacks land where the session already dispatches (same pattern as
         * folder/body Graph). A private MainContext here deadlocks startup. */
        var loop = new MainLoop ();
        this.session.send_and_read_async.begin (msg, Priority.DEFAULT, cancellable, (obj, res) => {
            try {
                bytes = this.session.send_and_read_async.end (res);
            } catch (Error e) {
                err = e;
            }
            loop.quit ();
        });
        loop.run ();
        if (err != null)
            throw new ApiError.HTTP ("Graph GET failed: %s".printf (err.message));
        if (bytes == null)
            throw new ApiError.HTTP ("Graph GET returned empty body");
        unowned uint8[] data = bytes.get_data ();
        if (msg.status_code < 200 || msg.status_code >= 300) {
            throw new ApiError.HTTP (
                "Graph HTTP %u: %s".printf (msg.status_code, bytes_to_utf8 (data))
            );
        }
        /* Soup Bytes are not NUL-terminated — always pass length to Json.Parser
         * or GLib walks past the buffer (random UTF-8 / '\\177' parse errors). */
        var parser = new Json.Parser ();
        try {
            parser.load_from_data ((string) data, data.length);
        } catch (Error e) {
            throw new ApiError.JSON ("Graph JSON: %s".printf (e.message));
        }
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
            throw new ApiError.JSON ("Graph response is not a JSON object");
        }
        return root.get_object ();
    }

    private static string? string_member_or_null (Json.Object o, string name) {
        if (!o.has_member (name) || o.get_member (name) == null || o.get_member (name).is_null ())
            return null;
        return o.get_string_member (name);
    }

    private static string? format_recipient (Json.Object o, string member) {
        if (!o.has_member (member) || o.get_member (member) == null
            || o.get_member (member).is_null ())
            return null;
        var from_o = o.get_object_member (member);
        if (!from_o.has_member ("emailAddress"))
            return null;
        var ea = from_o.get_object_member ("emailAddress");
        var n = ea.has_member ("name") ? ea.get_string_member ("name") : "";
        var a = ea.has_member ("address") ? ea.get_string_member ("address") : "";
        if ((n == null || n.length == 0) && (a == null || a.length == 0))
            return null;
        if (n == null || n.length == 0)
            return a;
        if (a == null || a.length == 0)
            return n;
        return "%s <%s>".printf (n, a);
    }

    private static string? format_recipients_array (Json.Object o, string member) {
        if (!o.has_member (member) || o.get_member (member) == null
            || o.get_member (member).is_null ())
            return null;
        if (o.get_member (member).get_node_type () != Json.NodeType.ARRAY)
            return null;
        var parts = new GenericArray<string> ();
        foreach (var node in o.get_array_member (member).get_elements ()) {
            var ro = node.get_object ();
            if (!ro.has_member ("emailAddress"))
                continue;
            var ea = ro.get_object_member ("emailAddress");
            var n = ea.has_member ("name") ? ea.get_string_member ("name") : "";
            var a = ea.has_member ("address") ? ea.get_string_member ("address") : "";
            if (a != null && a.length > 0 && n != null && n.length > 0)
                parts.add ("%s <%s>".printf (n, a));
            else if (a != null && a.length > 0)
                parts.add (a);
            else if (n != null && n.length > 0)
                parts.add (n);
        }
        if (parts.length == 0)
            return null;
        var sb = new StringBuilder ();
        for (uint i = 0; i < parts.length; i++) {
            if (i > 0)
                sb.append (", ");
            sb.append (parts[i]);
        }
        return sb.str;
    }

    private static string bytes_to_utf8 (uint8[] data) {
        if (data.length == 0)
            return "";
        /* Bound the view to data.length so we never read heap past the Bytes. */
        var raw = (string) data;
        if (raw.validate (data.length))
            return raw.substring (0, data.length);
        return raw.make_valid (data.length);
    }
}
