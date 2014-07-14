
module DBMod
  def self.wallfly_linefilter(line, verbose)
    if line =~ /\A([23])=(.*)\z/m
      kind, line = $1, $2
      if kind == "2"
        want = line =~ /  joined\sthe\sgame |
                          Fraglimit\shit |
                          JailPoint\sLimit\sHit |
                          moved\sto\sthe\ssidelines |
                          overflowed |
                          Timelimit\shit
                       /xi
        line = wallfly_colorize(line, kind)
      elsif kind == "3"
        return nil if line =~ /\Aconsole:/
#        return nil if line =~ /NoCheat V/
        txt = line.sub(/\A[^:]+:/, "")
        want = txt =~ /   admin |
                          aim\s*cheat |
                          aim\s*bot |
                          auto\s*aim |
                        \bban+(ed)?\b |
                        \bbot |
                        \bcheat |
                          console |
                          (crash|passw|start).*server |
                          frag\s*limit |
                          franck |
                          frq2 |
                          frkq2 |
                        \bhack |
                          how\s*much\s*(time|left) |
                          localhost |
                        \bmute |
                          private\s*message |
                          rcon |
                          server.*(crash|down|passw|start) |
                          speed\s*(bot|hack|cheat) |
                        \bvote |
                          time.*left |
                          time\s*limit |
                          xquake |
                          wallfly |
                        \b(board|level|map|stage).*\b(change|done|end|finished|over|too\s*(big|long)) |
                        \b(change|new|next|smaller|when).*\b(board|level|map)
                       /xi
        line = wallfly_colorize(line, kind)
      end
      return line if want || verbose
    end
    return nil
  end
  
  CHAT_HILITE_REGEX =
    / (
        console |
        admin |
        (aim\s*|\b)bot(\b|s|ter|ting|er|ing) |
        \bcheat\w* |
        \bha(ck\w*|x\w*) |
        \bwall(ed|ing|\s*ha[cx]\w*)
      )
    /ix

  def self.wallfly_colorize(line, kind)
    base_color = ANSI.color( ANSI::Reset, ((kind == "3") ? ANSI::Cyan : ANSI::White), ANSI::BGBlack )
    hilite_color = ANSI.color(ANSI::Bright, ANSI::Red, ANSI::BGBlack)
    line.gsub!(CHAT_HILITE_REGEX, hilite_color + "\\1" + base_color)
    base_color + line
  end
end


#        want = line =~ /  2\sor\smore\splayer\sname\smatches |
#                          \[LIKE\/RE\/CL\]
#                       /xi

