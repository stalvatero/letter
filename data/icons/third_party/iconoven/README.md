# IconOven (Stroke, round)

Selected UI icons from [@iconoven/svg](https://www.npmjs.com/package/@iconoven/svg) **1.0.1**,
Stroke style with round corners only.

- Upstream: https://iconoven.com
- License: MIT — see `LICENSE` (Copyright © 2026 Appic Marketing LLC)
- Only the free Stroke style is used; Pro styles are not included.

Letter ships these as **non-`-symbolic`** theme names. GTK’s symbolic
stylesheet forces `fill` and clears `stroke`, which turns IconOven outlines
into black squares. Artwork is optically scaled (~1.12) to match Adwaita size.

## Mapping

| IconOven file (round/) | Letter icon name |
|------------------------|------------------|
| puzzle.svg | letter-application-x-addon |
| user.svg | letter-avatar-default |
| bookmark-plus.svg | letter-bookmark-new |
| checkbox.svg | letter-checkbox-checked |
| palette.svg | letter-color-select |
| monitor.svg | letter-computer |
| loader.svg | letter-content-loading |
| file-edit.svg | letter-document-edit |
| history.svg | letter-document-open-recent |
| printer.svg | letter-document-print |
| save.svg | letter-document-save |
| hard-drive.svg | letter-drive-harddisk |
| x-circle.svg | letter-edit-clear |
| smile.svg | letter-face-smile |
| folder.svg | letter-folder |
| folder-open.svg | letter-folder-documents |
| folder-download.svg | letter-folder-download |
| outdent.svg | letter-format-indent-less |
| indent.svg | letter-format-indent-more |
| bold.svg | letter-format-text-bold |
| italic.svg | letter-format-text-italic |
| font.svg | letter-format-text-rich |
| strikethrough.svg | letter-format-text-strikethrough |
| underline.svg | letter-format-text-underline |
| chevron-right.svg | letter-go-next |
| info.svg | letter-help-about |
| image.svg | letter-image-x-generic |
| link.svg | letter-insert-link |
| plus.svg | letter-list-add |
| drag-handle.svg | letter-list-drag-handle |
| paperclip.svg | letter-mail-attachment |
| forward.svg | letter-mail-forward |
| flag.svg | letter-mail-mark-important |
| mail-spam.svg | letter-mail-mark-junk |
| send.svg | letter-mail-message-new |
| send.svg (stroke #fff) | letter-mail-message-new-on-accent |
| mail-open.svg | letter-mail-read |
| reply.svg | letter-mail-replied |
| reply-all.svg | letter-mail-reply-all |
| reply.svg | letter-mail-reply-sender |
| send.svg | letter-mail-send |
| refresh.svg | letter-mail-send-receive |
| mail.svg | letter-mail-unread |
| play.svg | letter-media-playback-start |
| penguin.svg | letter-network-workgroup |
| star-off.svg | letter-non-starred |
| check.svg | letter-object-select |
| menu.svg | letter-open-menu |
| archive.svg | letter-package-x-generic |
| chevron-down.svg | letter-pan-down |
| chevron-right.svg | letter-pan-end |
| palette.svg | letter-preferences-desktop-appearance |
| settings.svg | letter-preferences-system |
| sidebar-left.svg | letter-sidebar-show |
| star.svg | letter-starred |
| penguin.svg | letter-start-here |
| search.svg | letter-system-search |
| bookmark.svg | letter-user-bookmarks |
| trash.svg | letter-user-trash |
| list.svg | letter-view-list |
| list.svg | letter-view-list-bullet |
| list-ordered.svg | letter-view-list-ordered |
| eye.svg | letter-view-reveal |
| x-circle.svg | letter-window-close |
| contact-book.svg | letter-x-office-address-book |
| calendar.svg | letter-x-office-calendar |

Runtime copies: `data/icons/hicolor/symbolic/actions/letter-*.svg` and GResource
(`Utils.icon()` / `IconTheme.add_resource_path`).
