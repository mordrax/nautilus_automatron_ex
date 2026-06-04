# `:parity` tests shell out to the Python server venv and read the full real
# catalog; they are opt-in. Run them with `mix test --include parity`.
ExUnit.start(exclude: [:parity])
Ecto.Adapters.SQL.Sandbox.mode(AutomatronEx.Repo, :manual)
