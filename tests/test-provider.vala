void main () {
    assert (
        Mail.AccountKind.from_provider ("google", null) == Mail.AccountKind.GOOGLE
    );
    assert (
        Mail.AccountKind.from_provider ("Google", "imapx") == Mail.AccountKind.GOOGLE
    );
    assert (
        Mail.AccountKind.from_provider ("ms_graph", null) == Mail.AccountKind.MICROSOFT
    );
    assert (
        Mail.AccountKind.from_provider ("microsoft", "office365") == Mail.AccountKind.MICROSOFT
    );
    assert (
        Mail.AccountKind.from_provider ("windows_live", null) == Mail.AccountKind.MICROSOFT
    );
    assert (
        Mail.AccountKind.from_provider ("exchange", "ews") == Mail.AccountKind.EXCHANGE
    );
    assert (
        Mail.AccountKind.from_provider ("imap_smtp", "imapx") == Mail.AccountKind.IMAP
    );
    assert (
        Mail.AccountKind.from_provider (null, "maildir") == Mail.AccountKind.LOCAL
    );
    assert (
        Mail.AccountKind.from_provider ("unknown", "something") == Mail.AccountKind.OTHER
    );
}
