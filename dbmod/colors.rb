

# Add dorkbuster color classes to ANSI

# need separate color for sillyq2 "pain sounds"  (white?)


module ANSI
  Chat = Green
  Privmsg = [Bright, BGBlack, Yellow]
  DBCmd = Yellow
  DBErr = Red
  DBStatus = Yellow
  DBWarn = Yellow
  SillyQ2 = Green

  class << self
    # could use a function defining func here that, given the Constant, would
    # define the lowerase colorizing function below
    alias dbwarn              yellow
    alias dberr               red
    alias sillyq2             bright_magenta
    alias sillyq2_chat        green
    alias sillyq2_info        bright_magenta
    alias sillyq2_score_dead  bright_magenta
    alias wallfly             cyan
  end
end

