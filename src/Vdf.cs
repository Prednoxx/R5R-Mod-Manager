using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace R5R {
    public static class Vdf {
        sealed class Token { public string Text; public bool Symbol; public Token(string text, bool symbol) { Text = text; Symbol = symbol; } }
        static List<Token> Tokens(string text) {
            var result = new List<Token>();
            for (int i = 0; i < text.Length;) {
                if (Char.IsWhiteSpace(text[i]) || text[i] == '\uFEFF') { i++; continue; }
                if (text[i] == '/' && i + 1 < text.Length && text[i + 1] == '/') { while (i < text.Length && text[i] != '\n') i++; continue; }
                if (text[i] == '{' || text[i] == '}') { result.Add(new Token(text[i++].ToString(), true)); continue; }
                var word = new StringBuilder();
                if (text[i] == '"') {
                    i++; bool closed = false;
                    while (i < text.Length) {
                        char c = text[i++]; if (c == '"') { closed = true; break; }
                        if (c == '\\' && i < text.Length) { char next = text[i]; if (next == 'n') { word.Append('\n'); i++; } else if (next == 'r') { word.Append('\r'); i++; } else if (next == 't') { word.Append('\t'); i++; } else if (next == '"' || next == '\\') { word.Append(next); i++; } else word.Append(c); }
                        else word.Append(c);
                    }
                    if (!closed) throw new InvalidDataException("Unterminated string in mod.vdf.");
                } else { while (i < text.Length && !Char.IsWhiteSpace(text[i]) && text[i] != '{' && text[i] != '}') word.Append(text[i++]); }
                var value = word.ToString(); if (!(value.StartsWith("[") && value.EndsWith("]"))) result.Add(new Token(value, false));
            }
            return result;
        }
        public static Dictionary<string, object> Parse(string text) { var tokens = Tokens(text); int index = 0; return Block(tokens, ref index, false, 0); }
        static Dictionary<string, object> Block(List<Token> tokens, ref int index, bool nested, int depth) {
            if (depth > 64) throw new InvalidDataException("Mod metadata is nested too deeply.");
            var result = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            while (index < tokens.Count) {
                var key = tokens[index++];
                if (key.Symbol && key.Text == "}") { if (!nested) throw new InvalidDataException("Unexpected closing brace in mod.vdf."); return result; }
                if (key.Symbol || index >= tokens.Count) throw new InvalidDataException("Missing value in mod.vdf.");
                var value = tokens[index++];
                if (value.Symbol && value.Text == "{") result[key.Text] = Block(tokens, ref index, true, depth + 1);
                else if (value.Symbol) throw new InvalidDataException("Missing value in mod.vdf.");
                else result[key.Text] = value.Text;
            }
            if (nested) throw new InvalidDataException("Missing closing brace in mod.vdf.");
            return result;
        }
        public static string Get(Dictionary<string, object> value, string key) { object item; return value.TryGetValue(key, out item) && item is string ? (string)item : ""; }
        public static ModItem Metadata(string path) { return MetadataText(File.ReadAllText(path)); }
        public static ModItem MetadataText(string text) {
            var root = Parse(text); object block; var value = root.TryGetValue("mod", out block) && block is Dictionary<string, object> ? (Dictionary<string, object>)block : root;
            var item = new ModItem { Id = Get(value, "id"), Name = Get(value, "name"), Version = Get(value, "version"), Author = Get(value, "author"), Description = Get(value, "description") };
            if (value.TryGetValue("ConVars", out block) && block is Dictionary<string, object>) item.ConVars = ((Dictionary<string, object>)block).Keys.ToArray();
            var dependencies = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var key in new[] { "Dependencies", "RequiredMods" }) if (value.TryGetValue(key, out block) && block is Dictionary<string, object>) foreach (var pair in (Dictionary<string, object>)block) if (Convert.ToString(pair.Value) != "0") dependencies.Add(pair.Key);
            item.Deps = dependencies.ToArray(); return item;
        }
        public static string Quote(string value) { return "\"" + (value ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t") + "\""; }
        public static string WriteSwitches(string root, IDictionary<string, string> states) { var text = new StringBuilder(Quote(root) + "\r\n{\r\n"); foreach (var pair in states) text.Append("\t" + Quote(pair.Key) + "\t\t" + Quote(pair.Value) + "\r\n"); return text.Append("}\r\n").ToString(); }
    }
}
