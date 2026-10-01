test_provider = executable(
  'test-provider',
  [
    meson.project_source_root() / 'src' / 'account.vala',
    'test-provider.vala',
  ],
  dependencies: [
    glib_dep,
    dependency('gobject-2.0'),
  ],
  include_directories: config_h_dir,
)

test('provider', test_provider)

test_threading = executable(
  'test-threading',
  [
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'conversation.vala',
    'test-threading-stubs.vala',
    'test-threading.vala',
  ],
  dependencies: [
    glib_dep,
    gtk_dep,
    dependency('gobject-2.0'),
  ],
  include_directories: config_h_dir,
  vala_args: [
    '--pkg', 'gtk4',
  ],
)

test('threading', test_threading)

test_important_cache = executable(
  'test-important-cache',
  mail_sources + files('test-important-cache.vala'),
  mail_resources,
  dependencies: mail_deps,
  include_directories: config_h_dir,
  vala_args: [
    '--gresourcesdir', meson.project_build_root() / 'src',
  ],
)

test('important-cache', test_important_cache)
