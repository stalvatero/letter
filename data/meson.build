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
