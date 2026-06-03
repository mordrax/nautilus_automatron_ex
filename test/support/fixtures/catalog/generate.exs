# Regenerates the committed fixture catalog under test/support/fixtures/catalog/
# from the real NautilusTrader catalog.
#
# Run from the project root:
#
#     mix run --no-start test/support/fixtures/catalog/generate.exs
#
# Override the source catalog with NAEC_REAL_CATALOG=/path/to/backtest_catalog.
#
# Why these choices (see docs/catalog-schema.md for the full schema recon):
#   * Nautilus feathers are Arrow IPC *stream* format -> read with from_ipc_stream/1.
#   * Empty run 017f6297 (0 closed positions) is copied byte-for-byte so the
#     fixture keeps Nautilus's exact 0-row schema and exercises the
#     zero-position metrics branch.
#   * Populated run e4599dab keeps ALL rows (re-encoded compactly by Explorer),
#     so metrics computed on the fixture equal the real run's numbers -> true
#     parity test material.
#   * One bar_type, one parquet, truncated to @bar_limit rows; the output file is
#     renamed to the Nautilus `{ts_min}_{ts_max}.parquet` convention computed
#     from the truncated data.

defmodule FixtureGen do
  alias Explorer.DataFrame, as: DF
  alias Explorer.Series, as: S

  # Empty run (0 closed positions) — zero-position metrics branch.
  @empty_run "017f6297-c633-4419-aa23-bc3fb8171cad"
  # Populated run (204 closed positions, EMACross-000) — all rows kept.
  @pop_run "e4599dab-fd51-4758-9564-c2061bc2104e"

  # One bar_type, single parquet file, truncated to keep the fixture small.
  @bar_type "XAUUSD.IBCFD-5-MINUTE-MID-EXTERNAL"
  @bar_limit 300
  # Safety cap for event feathers (both runs are well under this; all rows kept).
  @event_limit 1000

  @feathers ["position_closed_0.feather", "order_filled_0.feather"]

  def run(real, dest) do
    IO.puts("source : #{real}")
    IO.puts("dest   : #{dest}\n")
    File.dir?(real) || raise "source catalog not found: #{real}"

    File.rm_rf!(Path.join(dest, "backtest"))
    File.rm_rf!(Path.join(dest, "data"))

    copy_run(real, dest, @empty_run, :verbatim)
    copy_run(real, dest, @pop_run, :rewrite)
    copy_bar(real, dest, @bar_type)

    IO.puts("\nfixture catalog written under #{dest}")
  end

  defp copy_run(real, dest, run_id, mode) do
    src = Path.join([real, "backtest", run_id])
    out = Path.join([dest, "backtest", run_id])
    File.mkdir_p!(out)

    # config.json is copied byte-exact (config-parse tests depend on it).
    File.cp!(Path.join(src, "config.json"), Path.join(out, "config.json"))

    for f <- @feathers do
      sp = Path.join(src, f)
      op = Path.join(out, f)

      case mode do
        :verbatim ->
          File.cp!(sp, op)

          IO.puts(
            "  #{run_id}/#{f}: copied verbatim (#{DF.n_rows(DF.from_ipc_stream!(op))} rows)"
          )

        :rewrite ->
          df = DF.from_ipc_stream!(sp)
          n = DF.n_rows(df)
          kept = if n > @event_limit, do: DF.head(df, @event_limit), else: df
          DF.to_ipc_stream!(kept, op)
          IO.puts("  #{run_id}/#{f}: #{n} -> #{DF.n_rows(kept)} rows")
      end
    end
  end

  defp copy_bar(real, dest, bar_type) do
    src_dir = Path.join([real, "data", "bar", bar_type])
    out_dir = Path.join([dest, "data", "bar", bar_type])
    File.mkdir_p!(out_dir)

    [file | _] =
      src_dir
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".parquet"))
      |> Enum.sort()

    df = DF.from_parquet!(Path.join(src_dir, file))
    kept = DF.head(df, @bar_limit)

    name =
      "#{nautilus_ts(S.min(kept["ts_event"]))}_#{nautilus_ts(S.max(kept["ts_event"]))}.parquet"

    DF.to_parquet!(kept, Path.join(out_dir, name))
    IO.puts("  bar/#{bar_type}/#{name}: #{DF.n_rows(df)} -> #{DF.n_rows(kept)} rows")
  end

  # Nautilus catalog timestamp format, e.g. 2026-02-25T23-05-00-000000000Z
  defp nautilus_ts(ns) do
    dt = DateTime.from_unix!(div(ns, 1_000_000_000), :second)
    sub = rem(ns, 1_000_000_000)

    "#{p(dt.year, 4)}-#{p(dt.month, 2)}-#{p(dt.day, 2)}T" <>
      "#{p(dt.hour, 2)}-#{p(dt.minute, 2)}-#{p(dt.second, 2)}-#{p(sub, 9)}Z"
  end

  defp p(n, w), do: n |> Integer.to_string() |> String.pad_leading(w, "0")
end

real =
  System.get_env("NAEC_REAL_CATALOG", "/Users/mordrax/code/nautilus_automatron/backtest_catalog")

dest = Path.join(File.cwd!(), "test/support/fixtures/catalog")
FixtureGen.run(real, dest)
