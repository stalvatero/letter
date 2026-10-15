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

test_people = executable(
  'test-people',
  [
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'people.vala',
    'test-people.vala',
  ],
  dependencies: [
    glib_dep,
    gtk_dep,
    adw_dep,
    dependency('gobject-2.0'),
  ],
  include_directories: config_h_dir,
)

test('people', test_people)

test_rows = executable(
  'test-rows',
  [
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'account-row.vala',
    meson.project_source_root() / 'src' / 'conversation.vala',
    'test-threading-stubs.vala',
    'test-rows.vala',
  ],
  dependencies: [
    glib_dep,
    gtk_dep,
    adw_dep,
    dependency('gobject-2.0'),
  ],
  include_directories: config_h_dir,
  vala_args: [
    '--pkg', 'gtk4',
    '--pkg', 'libadwaita-1',
  ],
)

test('rows', test_rows)

test_important_cache = executable(
  'test-important-cache',
  [
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'header-list-policy.vala',
    'test-important-cache.vala',
  ],
  dependencies: [
    glib_dep,
    dependency('gobject-2.0'),
  ],
  include_directories: config_h_dir,
)

test('important-cache', test_important_cache)

in_memory_settings_env = environment({
  'GSETTINGS_BACKEND': 'memory',
  'GSETTINGS_SCHEMA_DIR': meson.project_build_root() / 'data',
})

foreach name : ['content-policy', 'remote-content']
  test(
    name,
    executable(
      'test-' + name,
      mail_sources + files('test-' + name + '.vala'),
      mail_resources,
      dependencies: mail_deps,
      include_directories: config_h_dir,
      vala_args: [
        '--gresourcesdir', meson.project_build_root() / 'src',
      ],
    ),
    env: in_memory_settings_env,
  )
endforeach

test_account_avatars = executable(
  'test-account-avatars',
  [
    meson.project_source_root() / 'src' / 'config.vapi',
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'account-avatars.vala',
    'test-account-avatars.vala',
  ],
  dependencies: [
    glib_dep,
    gtk_dep,
    eds_dep,
    goa_dep,
    soup_dep,
    json_glib_dep,
  ],
  include_directories: config_h_dir,
)

test(
  'account-avatars',
  test_account_avatars,
  env: in_memory_settings_env,
)

test_thread_index = executable(
  'test-thread-index',
  [
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'thread-index.vala',
    'test-thread-index.vala',
  ],
  dependencies: [
    glib_dep,
    dependency('gobject-2.0'),
  ],
  include_directories: config_h_dir,
)

test('thread-index', test_thread_index)
