desktop_conf = configuration_data()
desktop_conf.set('app_id', app_id)
desktop_conf.set('app_name', app_name)
desktop_conf.set('icon', app_id)
desktop_conf.set('bindir', prefix / get_option('bindir'))

desktop_file = i18n.merge_file(
  input: configure_file(
    input: 'io.github.stalvatero.Letter.desktop.in.in',
    output: app_id + '.desktop.in',
    configuration: desktop_conf,
  ),
  output: app_id + '.desktop',
  type: 'desktop',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: datadir / 'applications',
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('validate-desktop', desktop_utils, args: [desktop_file])
endif

metainfo_conf = configuration_data()
metainfo_conf.set('app_id', app_id)
metainfo_conf.set('app_name', app_name)
metainfo_conf.set('version', meson.project_version())

metainfo_file = i18n.merge_file(
  input: configure_file(
    input: 'io.github.stalvatero.Letter.metainfo.xml.in.in',
    output: app_id + '.metainfo.xml.in',
    configuration: metainfo_conf,
  ),
  output: app_id + '.metainfo.xml',
  po_dir: meson.project_source_root() / 'po',
  data_dirs: [meson.project_source_root() / 'po'],
  install: true,
  install_dir: datadir / 'metainfo',
)

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test(
    'validate-metainfo',
    appstreamcli,
    args: ['validate', '--no-net', '--explain', metainfo_file],
  )
endif

gschema_conf = configuration_data()
gschema_conf.set('app_id', app_id)
gschema_conf.set('gettext_package', meson.project_name())

gschema_file = configure_file(
  input: 'io.github.stalvatero.Letter.gschema.xml.in',
  output: app_id + '.gschema.xml',
  configuration: gschema_conf,
  install: true,
  install_dir: datadir / 'glib-2.0' / 'schemas',
)

mail_app_id = get_option('profile') == 'development' ? 'io.github.stalvatero.Mail.Devel' : 'io.github.stalvatero.Mail'

gschema_conf_mail = configuration_data()
gschema_conf_mail.set('app_id', mail_app_id)
gschema_conf_mail.set('gettext_package', meson.project_name())

mail_gschema_file = configure_file(
  input: 'io.github.stalvatero.Mail.gschema.xml.in',
  output: mail_app_id + '.gschema.xml',
  configuration: gschema_conf_mail,
  install: true,
  install_dir: datadir / 'glib-2.0' / 'schemas',
)

custom_target(
  'gschemas-compiled',
  input: [gschema_file, mail_gschema_file],
  output: 'gschemas.compiled',
  command: [
    find_program('glib-compile-schemas'),
    meson.current_build_dir(),
  ],
  build_by_default: true,
)

install_data(
  'icons/hicolor/scalable/apps/io.github.stalvatero.Letter.svg',
  rename: app_id + '.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'apps',
)

install_data(
  'icons/hicolor/symbolic/apps/io.github.stalvatero.Letter-symbolic.svg',
  rename: app_id + '-symbolic.svg',
  install_dir: datadir / 'icons' / 'hicolor' / 'symbolic' / 'apps',
)

# Letter chrome (IconOven stroke) — also in GResource. Names omit -symbolic.
install_data(
  [
    'icons/hicolor/symbolic/actions/letter-application-x-addon.svg',
    'icons/hicolor/symbolic/actions/letter-avatar-default.svg',
    'icons/hicolor/symbolic/actions/letter-bookmark-new.svg',
    'icons/hicolor/symbolic/actions/letter-checkbox-checked.svg',
    'icons/hicolor/symbolic/actions/letter-color-select.svg',
    'icons/hicolor/symbolic/actions/letter-computer.svg',
    'icons/hicolor/symbolic/actions/letter-content-loading.svg',
    'icons/hicolor/symbolic/actions/letter-document-edit.svg',
    'icons/hicolor/symbolic/actions/letter-document-open-recent.svg',
    'icons/hicolor/symbolic/actions/letter-document-print.svg',
    'icons/hicolor/symbolic/actions/letter-document-save.svg',
    'icons/hicolor/symbolic/actions/letter-drive-harddisk.svg',
    'icons/hicolor/symbolic/actions/letter-edit-clear.svg',
    'icons/hicolor/symbolic/actions/letter-face-smile.svg',
    'icons/hicolor/symbolic/actions/letter-folder-documents.svg',
    'icons/hicolor/symbolic/actions/letter-folder-download.svg',
    'icons/hicolor/symbolic/actions/letter-folder.svg',
    'icons/hicolor/symbolic/actions/letter-format-indent-less.svg',
    'icons/hicolor/symbolic/actions/letter-format-indent-more.svg',
    'icons/hicolor/symbolic/actions/letter-format-text-bold.svg',
    'icons/hicolor/symbolic/actions/letter-format-text-italic.svg',
    'icons/hicolor/symbolic/actions/letter-format-text-rich.svg',
    'icons/hicolor/symbolic/actions/letter-format-text-strikethrough.svg',
    'icons/hicolor/symbolic/actions/letter-format-text-underline.svg',
    'icons/hicolor/symbolic/actions/letter-go-next.svg',
    'icons/hicolor/symbolic/actions/letter-help-about.svg',
    'icons/hicolor/symbolic/actions/letter-image-x-generic.svg',
    'icons/hicolor/symbolic/actions/letter-insert-link.svg',
    'icons/hicolor/symbolic/actions/letter-list-add.svg',
    'icons/hicolor/symbolic/actions/letter-list-drag-handle.svg',
    'icons/hicolor/symbolic/actions/letter-mail-attachment.svg',
    'icons/hicolor/symbolic/actions/letter-mail-forward.svg',
    'icons/hicolor/symbolic/actions/letter-mail-mark-important.svg',
    'icons/hicolor/symbolic/actions/letter-mail-mark-junk.svg',
    'icons/hicolor/symbolic/actions/letter-mail-message-new-on-accent.svg',
    'icons/hicolor/symbolic/actions/letter-mail-message-new.svg',
    'icons/hicolor/symbolic/actions/letter-mail-read.svg',
    'icons/hicolor/symbolic/actions/letter-mail-replied.svg',
    'icons/hicolor/symbolic/actions/letter-mail-reply-all.svg',
    'icons/hicolor/symbolic/actions/letter-mail-reply-sender.svg',
    'icons/hicolor/symbolic/actions/letter-mail-send-receive.svg',
    'icons/hicolor/symbolic/actions/letter-mail-send-on-accent.svg',
    'icons/hicolor/symbolic/actions/letter-mail-send.svg',
    'icons/hicolor/symbolic/actions/letter-mail-unread.svg',
    'icons/hicolor/symbolic/actions/letter-media-playback-start.svg',
    'icons/hicolor/symbolic/actions/letter-network-workgroup.svg',
    'icons/hicolor/symbolic/actions/letter-non-starred.svg',
    'icons/hicolor/symbolic/actions/letter-object-select.svg',
    'icons/hicolor/symbolic/actions/letter-open-menu.svg',
    'icons/hicolor/symbolic/actions/letter-package-x-generic.svg',
    'icons/hicolor/symbolic/actions/letter-pan-down.svg',
    'icons/hicolor/symbolic/actions/letter-pan-end.svg',
    'icons/hicolor/symbolic/actions/letter-preferences-desktop-appearance.svg',
    'icons/hicolor/symbolic/actions/letter-preferences-system.svg',
    'icons/hicolor/symbolic/actions/letter-sidebar-show.svg',
    'icons/hicolor/symbolic/actions/letter-starred.svg',
    'icons/hicolor/symbolic/actions/letter-start-here.svg',
    'icons/hicolor/symbolic/actions/letter-system-search.svg',
    'icons/hicolor/symbolic/actions/letter-user-bookmarks.svg',
    'icons/hicolor/symbolic/actions/letter-user-trash.svg',
    'icons/hicolor/symbolic/actions/letter-view-list-bullet.svg',
    'icons/hicolor/symbolic/actions/letter-view-list-ordered.svg',
    'icons/hicolor/symbolic/actions/letter-view-list.svg',
    'icons/hicolor/symbolic/actions/letter-view-reveal.svg',
    'icons/hicolor/symbolic/actions/letter-window-close.svg',
    'icons/hicolor/symbolic/actions/letter-x-office-address-book.svg',
    'icons/hicolor/symbolic/actions/letter-x-office-calendar.svg',
  ],
  install_dir: datadir / 'icons' / 'hicolor' / 'scalable' / 'actions',
)
