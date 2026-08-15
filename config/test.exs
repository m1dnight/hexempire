import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hex_empire, HexEmpireWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "X6WpKW8bAimcOghx/FznWNfYWzWUeuu/ebQJYNlypfIjfMmilNxKBugpV+paE869",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Keep test saves out of the project directory
config :hex_empire, :save_dir, Path.join(System.tmp_dir!(), "hexempire_test_saves")

# Step the AI as fast as possible so LiveView tests don't wait out timers
config :hex_empire, :ai_delay, 1

# Shrink the GameStore disk-write debounce so store tests can poll for flushes
config :hex_empire, :game_store_flush_ms, 25
config :hex_empire, :match_ai_delay, 1
config :hex_empire, :push_sender, HexEmpire.PushSenderStub
