identity_spike_deps = [
  dependency('glib-2.0', version: '>= 2.80'),
  dependency('gio-2.0', version: '>= 2.80'),
  dependency('json-glib-1.0', version: '>= 1.6'),
  dependency('libsecret-1', version: '>= 0.20'),
]

executable(
  'letter-identity-spike',
  files(
    'main.vala',
    meson.project_source_root() / 'src' / 'account.vala',
    meson.project_source_root() / 'src' / 'identity-catalog.vala',
    meson.project_source_root() / 'src' / 'identity-secrets.vala',
  ),
  dependencies: identity_spike_deps,
  install: false,
)
