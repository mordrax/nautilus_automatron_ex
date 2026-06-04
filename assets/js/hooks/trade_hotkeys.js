// TradeHotkeys LiveView hook.
//
// Ports use-hotkeys.ts from the React app
// (packages/client/src/hooks/use-hotkeys.ts, used by pages/RunDetailPage.tsx):
// keyboard navigation of the trade list, gated on CapsLock and ignored while
// typing in an input/textarea.
//
//   CapsLock + ArrowLeft        -> prev_trade        (-1)
//   CapsLock + ArrowRight       -> next_trade        (+1)
//   CapsLock + Shift + ArrowLeft  -> prev_trade_fast (-50)
//   CapsLock + Shift + ArrowRight -> next_trade_fast (+50)
//
// The hook only attaches a document-level keydown listener; it does not manage
// the element's DOM, so the host element does not need phx-update="ignore".
// Each branch pushes to the LiveView, which clamps the index and pushes
// chart:focus_trade back to the CandlestickChart hook.
export default {
  mounted() {
    this._onKeydown = (e) => {
      // Only fire while CapsLock is ON (mirrors the React reference exactly).
      if (!e.getModifierState?.("CapsLock")) return

      // Skip hotkeys while typing in an input or textarea.
      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement
      ) {
        return
      }

      if (e.key === "ArrowLeft") {
        e.preventDefault()
        this.pushEvent(e.shiftKey ? "prev_trade_fast" : "prev_trade")
      } else if (e.key === "ArrowRight") {
        e.preventDefault()
        this.pushEvent(e.shiftKey ? "next_trade_fast" : "next_trade")
      }
    }

    document.addEventListener("keydown", this._onKeydown)
  },

  destroyed() {
    document.removeEventListener("keydown", this._onKeydown)
  },
}
