# The test save dir is a fixed tmp path; wipe it so .bin files from previous
# runs can't leak into this run via GameStore's disk fallback.
File.rm_rf!(Application.fetch_env!(:hex_empire, :save_dir))
File.mkdir_p!(Application.fetch_env!(:hex_empire, :save_dir))

ExUnit.start(exclude: [:tournament])
