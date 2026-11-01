// XtermSharp（github.com/migueldeicaza/XtermSharp，MIT，提交 1bed529）的终端引擎，原样拷进来；只在开头加了这几行
#nullable disable
using System;
namespace XtermSharp {
	public enum CursorStyle {
		BlinkBlock, SteadyBlock, BlinkUnderline, SteadyUnderline, BlinkingBar, SteadyBar
	}

	public class TerminalOptions {
		public int Cols, Rows;
		public bool ConvertEol = true, CursorBlink;
		public string TermName;
		public CursorStyle CursorStyle;
		public bool ScreenReaderMode;
		public int? Scrollback { get; }
		public int? TabStopWidth { get; }

		public TerminalOptions ()
		{
			Cols = 80;
			Rows = 25;
			TermName = "xterm";
			Scrollback = 1000;
			TabStopWidth = 8;
		}
	}
}
