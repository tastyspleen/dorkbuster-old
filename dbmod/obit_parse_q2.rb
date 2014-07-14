
module ObitParseQ2
  def self.parse_obit_line(line, db)
    case line
    when /^(.*?) suicides\.$/ then db.log_suicide($1, "suicide")
    when /^(.*?) cratered\.$/ then db.log_suicide($1, "cratered")
    when /^(.*?) was squished\.$/ then db.log_suicide($1, "squished")
    when /^(.*?) sank like a rock\.$/ then db.log_suicide($1, "drowned")
    when /^(.*?) melted\.$/ then db.log_suicide($1, "slime")
    when /^(.*?) does a back flip into the lava\.$/ then db.log_suicide($1, "lava")
    when /^(.*?) blew up\.$/ then db.log_suicide($1, "map_hazard")
    when /^(.*?) found a way out\.$/ then db.log_suicide($1, "map_hazard")
    when /^(.*?) saw the light\.$/ then db.log_suicide($1, "map_hazard")
    when /^(.*?) got blasted\.$/ then db.log_suicide($1, "map_hazard")
    when /^(.*?) was in the wrong place\.$/ then db.log_suicide($1, "map_hazard")
    when /^(.*?) died\.$/ then db.log_suicide($1, "map_hazard")
    #
    when /^(.*?) tried to put the pin back in\.$/ then db.log_suicide($1, "grenade")
    when /^(.*?) tripped on (?:his|her|its) own grenade\.$/ then db.log_suicide($1, "grenade")
    when /^(.*?) blew (?:him|her|it)self up\.$/ then db.log_suicide($1, "rl")
    when /^(.*?) should have used a smaller gun\.$/ then db.log_suicide($1, "bfg")
  # when /^(.*?) tried to spawn camp and had a slight problem\.$/ then db.log_suicide($1, "spawncamp_backfire")
    when /^(.*?) killed (?:him|her|it)self\.$/ then db.log_suicide($1, "suicide")
    when /^(.*?) sucked into (?:his|her|its) own trap\.$/ then db.log_suicide($1, "trap")
    #
    when /^(.*?) was blasted by (.*)$/ then db.log_frag($2, $1, "blaster")
    when /^(.*?) was gunned down by (.*)$/ then db.log_frag($2, $1, "sg")
    when /^(.*?) was blown away by (.*)'s super shotgun$/ then db.log_frag($2, $1, "ssg")
    when /^(.*?) was machinegunned by (.*)$/ then db.log_frag($2, $1, "mg")
    when /^(.*?) was cut in half by (.*)'s chaingun$/ then db.log_frag($2, $1, "cg")
    when /^(.*?) was popped by (.*)'s grenade$/ then db.log_frag($2, $1, "gl")
    when /^(.*?) was shredded by (.*)'s shrapnel$/ then db.log_frag($2, $1, "gl")
    when /^(.*?) ate (.*)'s rocket$/ then db.log_frag($2, $1, "rl")
    when /^(.*?) almost dodged (.*)'s rocket$/ then db.log_frag($2, $1, "rl")
    when /^(.*?) was melted by (.*)'s hyperblaster$/ then db.log_frag($2, $1, "hb")
    when /^(.*?) was railed by (.*)$/ then db.log_frag($2, $1, "rg")
    when /^(.*?) saw the pretty lights from (.*)'s BFG$/ then db.log_frag($2, $1, "bfg")
    when /^(.*?) was disintegrated by (.*)'s BFG blast$/ then db.log_frag($2, $1, "bfg")
    when /^(.*?) couldn't hide from (.*)'s BFG$/ then db.log_frag($2, $1, "bfg")
    when /^(.*?) caught (.*)'s handgrenade$/ then db.log_frag($2, $1, "grenade")
    when /^(.*?) didn't see (.*)'s handgrenade$/ then db.log_frag($2, $1, "grenade")
    when /^(.*?) feels (.*)'s pain$/ then db.log_frag($2, $1, "grenade")
    when /^(.*?) tried to invade (.*)'s personal space$/ then db.log_frag($2, $1, "telefrag")
    when /^(.*?) caught in trap by (.*)$/ then db.log_frag($2, $1, "trap")
    when /^(.*?) ripped to shreds by (.*)'s ripper gun$/ then db.log_frag($2, $1, "ripper")
    when /^(.*?) was evaporated by (.*)$/ then db.log_frag($2, $1, "phalanx")
  # else warn "OBIT PARSE FAIL: #{line}"
    end
  end
end


