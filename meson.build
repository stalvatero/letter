project(
  'letter',
  ['vala', 'c'],
  version: '0.9.0-beta.1',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 1.3',
  default_options: [
    'warning_level=2',
    'werror=false',
  ],
)

gnome = import('gnome')
i18n = import('i18n')

if get_option('profile') == 'development'
  app_id = 'io.github.stalvatero.Letter.Devel'
  app_name = 'Letter (Development)'
else
  app_id = 'io.github.stalvatero.Letter'
  app_name = 'Letter'
endif

resource_path = '/io/github/stalvatero/Letter'

valac = meson.get_compiler('vala')
if valac.version().version_compare('< 0.56.11')
  error('Vala 0.56.11 or newer is required')
endif

glib_dep = dependency('glib-2.0', version: '>= 2.80')
gio_unix_dep = dependency('gio-unix-2.0', version: '>= 2.80')
posix_dep = valac.find_library('posix')
gmodule_dep = dependency('gmodule-2.0')
gtk_dep = dependency('gtk4', version: '>= 4.16')
adw_dep = dependency('libadwaita-1', version: '>= 1.8')
gdk_pixbuf_dep = dependency('gdk-pixbuf-2.0', version: '>= 2.42')
camel_dep = dependency('camel-1.2', version: '>= 3.50')
eds_dep = dependency('libedataserver-1.2', version: '>= 3.50')
edsui_dep = dependency('libedataserverui4-1.0', version: '>= 3.50')
ebook_dep = dependency('libebook-1.2', version: '>= 3.50')
ecal_dep = dependency('libecal-2.0', version: '>= 3.50')
ical_dep = dependency('libical-glib')
goa_dep = dependency('goa-1.0', version: '>= 3.50')
webkit_dep = dependency('webkitgtk-6.0', version: '>= 2.44')
gsound_dep = dependency('gsound', version: '>= 1.0')

# Camel 3.58 renamed get_uids→dup_uids, search_by_expression→search_sync,
# and FolderSearch.util_hash_message_id→search_util_hash_message_id. Ubuntu
# Resolute ships 3.56; Arch is newer. Detect at configure time for Vala #if.
cc = meson.get_compiler('c')
have_camel_3_58 = cc.has_function(
  'camel_folder_dup_uids',
  prefix: '#include <camel/camel.h>',
  dependencies: camel_dep,
)
if have_camel_3_58
  add_project_arguments('--define=HAVE_CAMEL_3_58', language: 'vala')
endif

sushi = find_program('sushi', required: false)
if not sushi.found()
  warning('sushi is not installed. Attachment preview will fall back to the default app.')
endif

hunspell = find_program('hunspell', required: false)
if not hunspell.found()
  warning('hunspell is not installed. Compose will have no spell checking. On Arch: pacman -S hunspell and a dictionary for your language (hunspell-it, hunspell-en_us, …).')
endif

mail_deps = [
  glib_dep,
  gio_unix_dep,
  posix_dep,
  gmodule_dep,
  gtk_dep,
  adw_dep,
  gdk_pixbuf_dep,
  camel_dep,
  eds_dep,
  edsui_dep,
  ebook_dep,
  ecal_dep,
  ical_dep,
  goa_dep,
  webkit_dep,
  gsound_dep,
]

prefix = get_option('prefix')
datadir = prefix / get_option('datadir')
pkgdatadir = datadir / meson.project_name()

# Development runs via `meson devenv` and never installs .mo files into prefix.
if get_option('profile') == 'development'
  localedir = meson.project_build_root() / 'locale'
else
  localedir = prefix / get_option('localedir')
endif

conf = configuration_data()
conf.set_quoted('APP_ID', app_id)
conf.set_quoted('APP_NAME', app_name)
conf.set_quoted('RESOURCE_PATH', resource_path)
conf.set_quoted('GETTEXT_PACKAGE', meson.project_name())
conf.set_quoted('LOCALEDIR', localedir)
conf.set_quoted('PACKAGE_VERSION', meson.project_version())
conf.set_quoted('VERSION', meson.project_version())
conf.set_quoted('PROFILE', get_option('profile'))
conf.set('GOA_API_IS_SUBJECT_TO_CHANGE', 1)
configure_file(output: 'config.h', configuration: conf)

config_h_dir = include_directories('.')

add_project_arguments(
  '--target-glib=2.80',
  language: 'vala',
)

add_project_arguments(
  '-DGOA_API_IS_SUBJECT_TO_CHANGE',
  '-DGETTEXT_PACKAGE="' + meson.project_name() + '"',
  language: 'c',
)

subdir('data')
subdir('src')
subdir('po')
subdir('tests')

meson.add_devenv({
  'GSETTINGS_SCHEMA_DIR': meson.project_build_root() / 'data',
})

gnome.post_install(
  gtk_update_icon_cache: true,
  glib_compile_schemas: true,
  update_desktop_database: true,
)
