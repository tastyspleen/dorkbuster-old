#!/usr/bin/env ruby

sv_cfg_filename = "server-info.cfg"
abort("Server config file #{sv_cfg_filename} not found. Please see server-example.cfg") unless test ?f, sv_cfg_filename
load sv_cfg_filename

def has_svdir?(nick)
  has = test(?d, File.join("./sv", nick))
# warn "no_svdir: #{nick}" unless has
  has
end

puts( ServerInfo.server_list.select{|sv| sv.has_key?(:dbip) && has_svdir?(sv.nick)}.collect{|sv| sv.nick}.sort.join(" ") )

