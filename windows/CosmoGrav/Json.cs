using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace CosmoGrav
{
    /// A small JSON reader and writer, enough for yt-dlp's output, GitHub's API and the app's own files.
    /// Objects become Dictionary<string, object>, arrays List<object>, numbers double.
    static class Json
    {
        public static object Parse(string text)
        {
            var reader = new Reader(text ?? "");
            reader.SkipSpace();
            var value = reader.ReadValue();
            reader.SkipSpace();
            if (!reader.AtEnd) throw new FormatException("Extra text after JSON.");
            return value;
        }

        public static Dictionary<string, object> TryParseObject(string text)
        {
            try { return Parse(text) as Dictionary<string, object>; } catch { return null; }
        }

        public static string Stringify(object value, bool indent = false)
        {
            var sb = new StringBuilder();
            Write(sb, value, indent, 0);
            return sb.ToString();
        }

        // MARK: Reading helpers

        public static string Str(this Dictionary<string, object> o, string key) =>
            o != null && o.TryGetValue(key, out var v) ? v as string : null;

        public static double? Num(this Dictionary<string, object> o, string key) =>
            o != null && o.TryGetValue(key, out var v) && v is double d ? d : (double?)null;

        public static int? Int(this Dictionary<string, object> o, string key)
        {
            var d = o.Num(key);
            return d.HasValue ? (int)Math.Round(d.Value) : (int?)null;
        }

        public static bool? Bool(this Dictionary<string, object> o, string key) =>
            o != null && o.TryGetValue(key, out var v) && v is bool b ? b : (bool?)null;

        public static Dictionary<string, object> Obj(this Dictionary<string, object> o, string key) =>
            o != null && o.TryGetValue(key, out var v) ? v as Dictionary<string, object> : null;

        public static List<Dictionary<string, object>> Objs(this Dictionary<string, object> o, string key)
        {
            var list = new List<Dictionary<string, object>>();
            if (o != null && o.TryGetValue(key, out var v) && v is List<object> items)
                foreach (var item in items) if (item is Dictionary<string, object> d) list.Add(d);
            return list;
        }

        // MARK: Reader

        sealed class Reader
        {
            readonly string s;
            int i;
            public Reader(string text) { s = text; }
            public bool AtEnd => i >= s.Length;

            public void SkipSpace() { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

            public object ReadValue()
            {
                SkipSpace();
                if (AtEnd) throw new FormatException("Unexpected end of JSON.");
                char c = s[i];
                switch (c)
                {
                    case '{': return ReadObject();
                    case '[': return ReadArray();
                    case '"': return ReadString();
                    case 't': Expect("true"); return true;
                    case 'f': Expect("false"); return false;
                    case 'n': Expect("null"); return null;
                    case 'N': Expect("NaN"); return double.NaN;
                    case 'I': Expect("Infinity"); return double.PositiveInfinity;
                    default: return ReadNumber();
                }
            }

            void Expect(string word)
            {
                if (string.CompareOrdinal(s, i, word, 0, word.Length) != 0) throw new FormatException("Bad JSON near " + i);
                i += word.Length;
            }

            Dictionary<string, object> ReadObject()
            {
                var result = new Dictionary<string, object>();
                i++;
                SkipSpace();
                if (i < s.Length && s[i] == '}') { i++; return result; }
                while (true)
                {
                    SkipSpace();
                    var key = ReadString();
                    SkipSpace();
                    if (AtEnd || s[i] != ':') throw new FormatException("Expected ':' at " + i);
                    i++;
                    result[key] = ReadValue();
                    SkipSpace();
                    if (AtEnd) throw new FormatException("Unclosed object.");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == '}') { i++; return result; }
                    throw new FormatException("Expected ',' or '}' at " + i);
                }
            }

            List<object> ReadArray()
            {
                var result = new List<object>();
                i++;
                SkipSpace();
                if (i < s.Length && s[i] == ']') { i++; return result; }
                while (true)
                {
                    result.Add(ReadValue());
                    SkipSpace();
                    if (AtEnd) throw new FormatException("Unclosed array.");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == ']') { i++; return result; }
                    throw new FormatException("Expected ',' or ']' at " + i);
                }
            }

            string ReadString()
            {
                if (AtEnd || s[i] != '"') throw new FormatException("Expected a string at " + i);
                i++;
                var sb = new StringBuilder();
                while (i < s.Length)
                {
                    char c = s[i++];
                    if (c == '"') return sb.ToString();
                    if (c != '\\') { sb.Append(c); continue; }
                    if (AtEnd) break;
                    char e = s[i++];
                    switch (e)
                    {
                        case 'n': sb.Append('\n'); break;
                        case 'r': sb.Append('\r'); break;
                        case 't': sb.Append('\t'); break;
                        case 'b': sb.Append('\b'); break;
                        case 'f': sb.Append('\f'); break;
                        case 'u':
                            sb.Append((char)Convert.ToInt32(s.Substring(i, 4), 16));
                            i += 4;
                            break;
                        default: sb.Append(e); break;
                    }
                }
                throw new FormatException("Unclosed string.");
            }

            double ReadNumber()
            {
                int start = i;
                if (s[i] == '-') { i++; if (i < s.Length && s[i] == 'I') { Expect("Infinity"); return double.NegativeInfinity; } }
                while (i < s.Length && "0123456789+-.eE".IndexOf(s[i]) >= 0) i++;
                if (i == start) throw new FormatException("Unexpected character at " + i);
                return double.Parse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture);
            }
        }

        // MARK: Writer

        static void Write(StringBuilder sb, object value, bool indent, int depth)
        {
            switch (value)
            {
                case null: sb.Append("null"); break;
                case string str: WriteString(sb, str); break;
                case bool b: sb.Append(b ? "true" : "false"); break;
                case double d: sb.Append(double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString("R", CultureInfo.InvariantCulture)); break;
                case float f: sb.Append(((double)f).ToString("R", CultureInfo.InvariantCulture)); break;
                case int n: sb.Append(n.ToString(CultureInfo.InvariantCulture)); break;
                case long l: sb.Append(l.ToString(CultureInfo.InvariantCulture)); break;
                case IDictionary dict:
                    {
                        sb.Append('{');
                        bool first = true;
                        foreach (DictionaryEntry entry in dict)
                        {
                            if (!first) sb.Append(',');
                            first = false;
                            if (indent) { sb.Append('\n'); sb.Append(' ', (depth + 1) * 2); }
                            WriteString(sb, entry.Key.ToString());
                            sb.Append(indent ? ": " : ":");
                            Write(sb, entry.Value, indent, depth + 1);
                        }
                        if (indent && !first) { sb.Append('\n'); sb.Append(' ', depth * 2); }
                        sb.Append('}');
                        break;
                    }
                case IEnumerable list:
                    {
                        sb.Append('[');
                        bool first = true;
                        foreach (var item in list)
                        {
                            if (!first) sb.Append(',');
                            first = false;
                            if (indent) { sb.Append('\n'); sb.Append(' ', (depth + 1) * 2); }
                            Write(sb, item, indent, depth + 1);
                        }
                        if (indent && !first) { sb.Append('\n'); sb.Append(' ', depth * 2); }
                        sb.Append(']');
                        break;
                    }
                default: WriteString(sb, Convert.ToString(value, CultureInfo.InvariantCulture)); break;
            }
        }

        static void WriteString(StringBuilder sb, string s)
        {
            sb.Append('"');
            foreach (char c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4"));
                        else sb.Append(c);
                        break;
                }
            }
            sb.Append('"');
        }
    }
}
