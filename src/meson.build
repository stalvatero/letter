blueprint_compiler = find_program('blueprint-compiler', required: true)

blueprints = custom_target(
  'blueprint-window',
  input: files(
    'window.blp',
  ),
  output: 'window.ui',
  command: [
    blueprint_compiler,
    'compile',
    '--output', '@OUTPUT@',
    '@INPUT@',
  ],
)

mail_resources = gnome.compile_resources(
  'mail-resources',
  'mail.gresource.xml',
  c_name: 'mail',
  source_dir: [
    meson.current_build_dir(),
    meson.current_source_dir(),
  ],
  dependencies: blueprints,
)

mail_sources = files(
  'config.vapi',
  'application.vala',
  'window.vala',
  'account.vala',
  'account-row.vala',
  'account-store.vala',
  'mail-session.vala',
  'body-index.vala',
  'notifier.vala',
  'conversation.vala',
  'message-reader.vala',
  'message-window.vala',
  'eml-viewer.vala',
  'attachment-chip.vala',
  'compose-dialog.vala',
  'outbox-store.vala',
  'recipient-editor.vala',
  'search-query.vala',
  'search-field.vala',
  'contact-store.vala',
  'contact-picker.vala',
  'calendar-store.vala',
  'invitation-bar.vala',
  'preferences-dialog.vala',
  'signature-store.vala',
  'signature-editor.vala',
  'dependency-page.vala',
  'welcome-dialog.vala',
  'welcome-tour.vala',
  'setup-window.vala',
  'format-toolbar.vala',
  'theme-selector.vala',
  'utils.vala',
)

executable(
  meson.project_name(),
  mail_sources + files('main.vala'),
  mail_resources,
  dependencies: mail_deps,
  include_directories: config_h_dir,
  vala_args: [
    '--gresourcesdir', meson.current_build_dir(),
  ],
  export_dynamic: true,
  install: true,
)
