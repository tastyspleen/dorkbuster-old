
class UserSec
  attr_reader :user, :member_groups
  def initialize(user, member_groups)
    @user = user ? user.dup.freeze : nil
    @member_groups = member_groups.dup.freeze
  end
end

class DBNode
  attr_reader :name, :perm, :owner, :group

  def initialize(name, perm, owner, group)
    @name, @perm, @owner, @group = name, perm, owner, group
    @children = nil
    @parent = nil
    @attr = nil
    # if adding a new instance var, see also: marshal_dump / marshal_load
  end

  def create(dirs, perm, owner, group, sec)
    return self if dirs.empty?
    childname = dirs.shift
    node = fetch_or_create_node(childname, perm, owner, group, sec)
    node.create(dirs, perm, owner, group, sec)
  end

  def unlink(sec)
    raise DBDB::DirectoryNotEmpty, mypathstr if @children && ! @children.empty?
    if @parent
      @parent.auth(PERM::W, sec)
      par = @parent
      @parent = nil
      par.children.delete(@name)
    end
    self
  end

  def exist?(dirs, sec)
    return true if dirs.empty?
    childname = dirs.shift
    node = fetch_node(childname, sec)
    node ? node.exist?(dirs, sec) : false
  end

  def fetch(dirs, sec)
    return self if dirs.empty?
    childname = dirs.shift
    node = fetch_node(childname, sec)
    raise DBDB::PathNotFound, "#{mypathstr}/#{childname}" unless node
    node.fetch(dirs, sec)
  end

  def parent(sec)
    auth(PERM::R, sec)
    @parent
  end

  def get(sec)
    auth(PERM::R, sec)
    @attr
  end

  def set(obj, sec)
    auth(PERM::W, sec)
    @attr = obj
  end

  def unset(sec)
    auth(PERM::W, sec)
    @attr = nil
  end

  def setperm(new_perm, sec)
    if @perm != new_perm
      raise DBDB::PermissionDenied, "#{mypathstr}" unless sec.user.nil? || @owner == sec.user
      @perm = new_perm
    end
  end
  
  def setowner(new_owner, sec)
    if @owner != new_owner
      raise DBDB::PermissionDenied, "#{mypathstr}" unless sec.user.nil?
      @owner = new_owner
    end
  end

  def setgroup(new_group, sec)
    if @group != new_group
      raise DBDB::PermissionDenied, "#{mypathstr}" unless sec.user.nil? || (@owner == sec.user  &&  sec.member_groups.include?(new_group))
      @group = new_group
    end
  end

  def childlist(sec)
    auth(PERM::R, sec)
    @children ? @children.to_a.sort.collect {|pair| pair[1]} : []
  end

  def mypathstr
    mypath.map {|node| node.name}.join("/")
  end

  def each(&block)
    yield self
    @children.each_value {|n| n.each(&block) } if @children
  end

  alias :apply_all :each

  # 1. only owner can chmod
  # 2. Perms are applied strongest-class-exclusive: strongest
  #    classes are owner, then group, then other (weakest).
  #    So they are exclusionary, you can't jump class.  Your
  #    class is determined by selecting the strongest available.
  #    That means the owner can exclude a group from having
  #    permissions.  
  def auth(wanted_perm, accessor_sec)
    return true if accessor_sec.user.nil?
    granted_perm = get_accessor_rights(accessor_sec)
    access_granted = (wanted_perm & granted_perm) == wanted_perm
    raise DBDB::PermissionDenied, "#{mypathstr}" unless access_granted
  end

  def marshal_dump
    fields = [@name, @perm, @owner, @group, @children, @parent]
    fields << ( @attr.kind_of?(DBDB::Undumped) ? nil : @attr )
    fields
  end

  def marshal_load(fields)
    @name, @perm, @owner, @group, @children, @parent, @attr = *fields
  end

  protected
  
  attr_writer :parent
  attr_reader :children

  def get_accessor_rights(accessor_sec)
    if @owner == accessor_sec.user
      @perm[PERM::USER]
    elsif accessor_sec.member_groups.include? @group
      @perm[PERM::GROUP]
    else
      @perm[PERM::OTHER]
    end
  end

  def new_child(name, perm, owner, group)
# $stderr.puts "new_child: #{name}, #{perm.inspect}, #{owner.inspect}:#{group.inspect}"
    @children[name] = (child = DBNode.new(name, perm, owner, group))
    child.parent = self
    child
  end

  # NOTE: fetch_or_create_node is currently used only by #create
  # The permissions only require W if the node is being created,
  # else R if the node is being fetched.
  def fetch_or_create_node(name, perm, owner, group, sec)
    if name == "."
      self
    elsif name == ".."
      raise DBDB::PathNotFound, "#{mypathstr}/#{name}" unless @parent
      auth(PERM::R, sec)
      @parent
    elsif ! @children  ||  ! @children.has_key?(name)
      auth(PERM::W, sec)
      @children ||= {}
      new_child(name, perm, owner, group)
    else
      auth(PERM::R, sec)
      @children[name]
    end
  end  

  def fetch_node(name, sec)
    auth(PERM::R, sec) unless name == "."
    if name == "."
      self
    elsif name == ".."
      @parent
    else
      @children ? @children[name] : nil
    end
  end

  def mypath(result=[])
    result.unshift self
    @parent.mypath(result) if @parent
    result
  end
    
end

class DBDB

  module PERM
    NONE = 0
    R = 1
    W = 2
    RW = R|W
    USER = 0
    GROUP = 1
    OTHER = 2
  end

  DEFAULT_PERM = [PERM::RW, PERM::R, PERM::R]

  module Undumped; end

  class PermissionDenied < StandardError; end
  class DirectoryNotEmpty < StandardError; end
  class PathNotFound < StandardError; end

  def initialize(filepath=nil)
    if filepath
      @db = File.open(filepath, "rb") {|io| Marshal.load(io) }
    else
      @db = DBNode.new("", DEFAULT_PERM, nil, nil)
    end
  end

  def close
    # TODO - flush db to file
  end

  def store(filepath)
    File.open(filepath, "wb") {|io| Marshal.dump(@db, io) }
  end

  def self.load(filepath)
    new(filepath)
  end

  def create(abspath, perm_, owner_, group_, sec)
    dirs = abspath_to_dirs_list(abspath)
    @db.create(dirs, perm_, owner_, group_, sec)
  end

  def unlink(abspath, sec)
    node = fetch(abspath, sec)
    node.unlink(sec)
  end
  
  def dir(abspath, sec)
    node = fetch(abspath, sec)
    node.childlist(sec)
  end

  def get(abspath, sec)
    leaf = fetchleaf(abspath, sec)
    leaf ? leaf.get(sec) : nil
  end

  def set(abspath, obj, perm_, owner_, group_, sec)
    node = createleaf(abspath, perm_, owner_, group_, sec)
    node.set(obj, sec)
  end

  def unset(abspath, sec)
    leaf = fetchleaf(abspath, sec)
    leaf.unset(sec) if leaf
  end

  def fetch(abspath, sec)
    @db.fetch(abspath_to_dirs_list(abspath), sec)
  end

  def perm(abspath, sec)
    node = fetch(abspath, sec)
    node.perm
  end

  def owner(abspath, sec)
    node = fetch(abspath, sec)
    node.owner
  end

  def group(abspath, sec)
    node = fetch(abspath, sec)
    node.group
  end
  
  def setperm(abspath, new_perm, sec)
    node = fetch(abspath, sec)
    node.setperm(new_perm, sec)
  end
  
  def setowner(abspath, new_owner, sec)
    node = fetch(abspath, sec)
    node.setowner(new_owner, sec)
  end

  def setgroup(abspath, new_group, sec)
    node = fetch(abspath, sec)
    node.setgroup(new_group, sec)
  end

  def setperm_r(abspath, new_perm, sec)
    node = fetch(abspath, sec)
    node.apply_all {|n| n.setperm(new_perm, sec) }
  end

  def setowner_r(abspath, new_owner, sec)
    node = fetch(abspath, sec)
    node.apply_all {|n| n.setowner(new_owner, sec) }
  end

  def setgroup_r(abspath, new_group, sec)
    node = fetch(abspath, sec)
    node.apply_all {|n| n.setgroup(new_group, sec) }
  end


  private
  
  def abspath_to_dirs_list(abspath)
    dirs = abspath.split(/\/+/)
    dirs.shift if abspath[0] == ?/
    dirs
  end

  # Fetches leaf node.  Raises PathNotFound if branch
  # doesn't exist, but returns nil if leaf doesn't exist.
  def fetchleaf(abspath, sec)
    dirs = abspath_to_dirs_list(abspath)
    if dirs.empty?
      @db
    else
      leaf = dirs.pop
      par = @db.fetch(dirs, sec)
      if par.exist?([leaf], sec)
        par.fetch([leaf], sec)
      else
        nil
      end
    end
  end

  def createleaf(abspath, perm_, owner_, group_, sec)
    dirs = abspath_to_dirs_list(abspath)
    if dirs.empty?
      @db
    else
      leaf = dirs.pop
      par = @db.fetch(dirs, sec)
      par.create([leaf], perm_, owner_, group_, sec)
    end
  end

end

class DBNode; PERM = DBDB::PERM; end

class DBAccessor

  PERM = DBDB::PERM

  attr_accessor :defperm

  def initialize(db, user, member_groups, initial_dir="/")
    @db, @sec = db, UserSec.new(user, member_groups)
    @primary_group = user  # for now, user's primary group is always same as username
    @cwd = initial_dir
    @defperm = DBDB::DEFAULT_PERM
  end

  def member_groups
    @sec.member_groups
  end
  
  def pwd
    return @cwd
  end

  def dir(path=@cwd)
    @db.dir(get_abs_path(path), @sec).map {|node| node.name }
  end

  def attrs(path=@cwd)
    @db.dir(get_abs_path(path), @sec).select {|node| node.get(@sec)}.map {|node| node.name }
  end

  def create(path)
    @db.create(get_abs_path(path), @defperm, @user, @primary_group, @sec)
  end

  def delete(path)
    @db.unlink(get_abs_path(path), @sec)
  end
  
  def get(path, default_value=nil)
    @db.get(get_abs_path(path), @sec) || default_value
  end

  def set(path, obj)
    @db.set(get_abs_path(path), obj, @defperm, @user, @primary_group, @sec)
  end

  def unset(path)
    @db.unset(get_abs_path(path), @sec)
  end

  def cd(path)
    new_cwd = get_abs_path(path)
    node = @db.fetch(new_cwd, @sec)  # fetch will raise if path not found
    @cwd = node.mypathstr
  end

  def perm(path)
    @db.perm(get_abs_path(path), @sec)
  end

  def owner(path)
    @db.owner(get_abs_path(path), @sec)
  end

  def group(path)
    @db.group(get_abs_path(path), @sec)
  end

  def setperm(path, new_perm)
    @db.setperm(get_abs_path(path), new_perm, @sec)
  end

  def setowner(path, new_owner)
    @db.setowner(get_abs_path(path), new_owner, @sec)
  end

  def setgroup(path, new_group)
    @db.setgroup(get_abs_path(path), new_group, @sec)
  end

  def setperm_r(path, new_perm)
    @db.setperm_r(get_abs_path(path), new_perm, @sec)
  end
  
  def setowner_r(path, new_owner)
    @db.setowner_r(get_abs_path(path), new_owner, @sec)
  end

  def setgroup_r(path, new_group)
    @db.setgroup_r(get_abs_path(path), new_group, @sec)
  end

  private
  
  def get_abs_path(maybe_rel_path)
    if maybe_rel_path[0] == ?/
      maybe_rel_path  # already abs
    else
      prefix = (@cwd == "/")? "" : @cwd
      [prefix, maybe_rel_path].join("/")
    end
  end
  
end


if $0 == __FILE__
  require 'test/unit'

  class TestDBNode < Test::Unit::TestCase

    PERM = DBDB::PERM

    def test_create
      root_sec = UserSec.new(nil, [])
      
      perms = DBDB::DEFAULT_PERM
      pog = [perms, "quadz", "quadzg"]
      root = DBNode.new("", *pog)
      assert_equal( "", root.name )
      
      pog = [perms, "quadz", "quadzg", root_sec]
      root.create(%w(a b c d), *pog)
      a = root.fetch(%w(a), root_sec)
      assert_equal( "a", a.name )
      b = root.fetch(%w(a b), root_sec)
      assert_equal( "b", b.name )
      c = root.fetch(%w(a b c), root_sec)
      assert_equal( "c", c.name )
      d = root.fetch(%w(a b c d), root_sec)
      assert_equal( "d", d.name )
      
      root.create(%w(a b c d e), *pog)
      e = root.fetch(%w(a b c d e), root_sec)
      assert_equal( "e", e.name )
      assert_equal( a.object_id, root.fetch(%w(a), root_sec).object_id )
      assert_equal( b.object_id, root.fetch(%w(a b), root_sec).object_id )
      assert_equal( c.object_id, root.fetch(%w(a b c), root_sec).object_id )
      assert_equal( d.object_id, root.fetch(%w(a b c d), root_sec).object_id )
      
      assert_equal( root.object_id, root.create([], *pog).object_id )
      assert_equal( a.object_id, root.create(%w(a), *pog).object_id )
      assert_equal( b.object_id, root.create(%w(a b), *pog).object_id )
      assert_equal( c.object_id, root.create(%w(a b c), *pog).object_id )
      assert_equal( d.object_id, root.create(%w(a b c d), *pog).object_id )
      assert_equal( e.object_id, root.create(%w(a b c d e), *pog).object_id )
      
      assert_raises(DBDB::PathNotFound) { root.fetch(%w(a b c d z), root_sec) }
    end

    def test_perm
      perm_r_r_r = [PERM::R, PERM::R, PERM::R]
      perm_rw_r_r = [PERM::RW, PERM::R, PERM::R]
      perm_rw_0_0 = [PERM::RW, PERM::NONE, PERM::NONE]
      perm_r_r_0 = [PERM::R, PERM::R, PERM::NONE]
      perm_r_0_r = [PERM::R, PERM::NONE, PERM::R]
      perm_w_w_w = [PERM::W, PERM::W, PERM::W]
      perm_w_0_w = [PERM::W, PERM::NONE, PERM::W]
      perm_w_w_0 = [PERM::W, PERM::W, PERM::NONE]
      perm_0_r_r = [PERM::NONE, PERM::R, PERM::R]
      perm_0_rw_r = [PERM::NONE, PERM::RW, PERM::R]
      perm_0_w_w = [PERM::NONE, PERM::W, PERM::W]
      perm_0_0_0 = [PERM::NONE, PERM::NONE, PERM::NONE]

      root_sec = UserSec.new(nil, [])
      quadz_sec = UserSec.new("quadz", %w(quadz admin))
      pantaloons_sec = UserSec.new("pantaloons", %w(pantaloons admin))
      bobo_sec = UserSec.new("bobo", %w(bobo))

      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_rw_r_r, perm_rw_r_r, perm_rw_0_0)

      assert_nothing_raised { users.auth(PERM::R, quadz_sec) }
      assert_raises(DBDB::PermissionDenied) { users.auth(PERM::W, quadz_sec) }
      assert_raises(DBDB::PermissionDenied) { users.auth(PERM::RW, quadz_sec) }
      
      assert_nothing_raised { users.auth(PERM::R, root_sec) }
      assert_nothing_raised { users.auth(PERM::W, root_sec) }
      assert_nothing_raised { users.auth(PERM::RW, root_sec) }
      
      assert_nothing_raised { users_quadz.setowner(nil, root_sec) }
      assert_nothing_raised { users_quadz.setgroup(nil, root_sec) }
      # test only superuser can chown
      assert_raises(DBDB::PermissionDenied) { users_quadz.setowner("quadz", quadz_sec) }
      assert_nothing_raised { users_quadz.setowner("quadz", root_sec) }
      # this doesn't raise because we're the owner and we're not changing it
      assert_nothing_raised { users_quadz.setowner("quadz", quadz_sec) }
      assert_raises(DBDB::PermissionDenied) { users_quadz.setowner("bobo", quadz_sec) }
      assert_raises(DBDB::PermissionDenied) { users_quadz.setowner("bobo", bobo_sec) }

      # test only owner (or superuser) can chmod
      assert_equal( "quadz", users_quadz.owner )
      assert_equal( nil, users_quadz.group )
      assert_equal( perm_rw_r_r, users_quadz.perm )
      assert_raises(DBDB::PermissionDenied) { users_quadz.setperm(perm_r_r_r, bobo_sec) }
      assert_nothing_raised { users_quadz.setperm(perm_r_r_r, quadz_sec) }
      assert_nothing_raised { users_quadz.setperm(perm_0_rw_r, quadz_sec) }
      assert_raises(DBDB::PermissionDenied) { users_quadz.setperm(perm_r_r_r, pantaloons_sec) }
      
      # test owner can chgrp only to a group owner is a member of
      # owner IS allowed to change a group FROM something owner is
      # not a member of, but could not change it back TO that group
      assert_nothing_raised { users_quadz.setperm(perm_0_0_0, quadz_sec) }
      assert_equal( "quadz", users_quadz.owner )
      assert_equal( nil, users_quadz.group )
      assert_equal( perm_0_0_0, users_quadz.perm )
      assert_equal( %w(quadz admin), quadz_sec.member_groups )
      # nothing raised because group already nil
      assert_nothing_raised { users_quadz.setgroup(nil, quadz_sec) }
      assert_equal( nil, users_quadz.group )
      # try a group we aren't a member of
      assert_raises(DBDB::PermissionDenied) { users_quadz.setgroup("superniftygroup", quadz_sec) }
      assert_equal( nil, users_quadz.group )
      # try our member groups
      assert_nothing_raised { users_quadz.setgroup("admin", quadz_sec) }
      assert_equal( "admin", users_quadz.group )
      assert_nothing_raised { users_quadz.setgroup("quadz", quadz_sec) }
      assert_equal( "quadz", users_quadz.group )
      assert_raises(DBDB::PermissionDenied) { users_quadz.setgroup("superniftygroup", quadz_sec) }
      assert_equal( "quadz", users_quadz.group )
      assert_raises(DBDB::PermissionDenied) { users_quadz.setgroup("nil", quadz_sec) }
      assert_equal( "quadz", users_quadz.group )
      # test even other group member can't chgrp
      assert_nothing_raised { users_quadz.setgroup("admin", quadz_sec) }
      assert_equal( "admin", users_quadz.group )
      assert_raises(DBDB::PermissionDenied) { users_quadz.setgroup("pantaloons", pantaloons_sec) }
      # test superuser can chgrp
      assert_nothing_raised { users_quadz.setgroup("pantaloons", root_sec) }
      assert_equal( "pantaloons", users_quadz.group )
      assert_nothing_raised { users_quadz.setgroup(nil, root_sec) }
      assert_equal( nil, users_quadz.group )
      
      # test perm_0_0_0
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_0_0, perm_0_0_0, perm_0_0_0)
      assert_equal( "quadz", users_quadz.owner )
      assert_equal( "admin", users_quadz.group )
      assert_equal( perm_0_0_0, users_quadz.perm )
      assert_equal( %w(quadz admin), quadz_sec.member_groups )
      
      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_denied(users_quadz, quadz_sec)
      verify_reads_denied(users_quadz, pantaloons_sec)
      verify_reads_denied(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_denied(users_quadz, quadz_sec)
      verify_writes_denied(users_quadz, pantaloons_sec)
      verify_writes_denied(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_denied(users_quadz, quadz_sec)
      verify_parent_reads_denied(users_quadz, pantaloons_sec)
      verify_parent_reads_denied(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_denied(users_quadz, "mbox", quadz_sec)
      verify_child_reads_denied(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_denied(users_quadz, "mbox", bobo_sec)

      verify_create_denied(users_quadz, "spleen", quadz_sec)
      verify_create_denied(users_quadz, "spleen", pantaloons_sec)
      verify_create_denied(users_quadz, "spleen", bobo_sec)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      verify_unlink_denied(users_quadz_mbox, quadz_sec)
      verify_unlink_denied(users_quadz_mbox, pantaloons_sec)
      verify_unlink_denied(users_quadz_mbox, bobo_sec)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_r_r_r
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_r_r_r, perm_r_r_r, perm_r_r_r)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_permitted(users_quadz, quadz_sec)
      verify_reads_permitted(users_quadz, pantaloons_sec)
      verify_reads_permitted(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_denied(users_quadz, quadz_sec)
      verify_writes_denied(users_quadz, pantaloons_sec)
      verify_writes_denied(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_permitted(users_quadz, quadz_sec)
      verify_parent_reads_permitted(users_quadz, pantaloons_sec)
      verify_parent_reads_permitted(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_permitted(users_quadz, "mbox", quadz_sec)
      verify_child_reads_permitted(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_permitted(users_quadz, "mbox", bobo_sec)

      verify_create_denied(users_quadz, "spleen", quadz_sec)
      verify_create_denied(users_quadz, "spleen", pantaloons_sec)
      verify_create_denied(users_quadz, "spleen", bobo_sec)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      verify_unlink_denied(users_quadz_mbox, quadz_sec)
      verify_unlink_denied(users_quadz_mbox, pantaloons_sec)
      verify_unlink_denied(users_quadz_mbox, bobo_sec)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_0_r_r
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_r_r, perm_0_r_r, perm_0_r_r)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_denied(users_quadz, quadz_sec)
      verify_reads_permitted(users_quadz, pantaloons_sec)
      verify_reads_permitted(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_denied(users_quadz, quadz_sec)
      verify_writes_denied(users_quadz, pantaloons_sec)
      verify_writes_denied(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_denied(users_quadz, quadz_sec)
      verify_parent_reads_permitted(users_quadz, pantaloons_sec)
      verify_parent_reads_permitted(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_denied(users_quadz, "mbox", quadz_sec)
      verify_child_reads_permitted(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_permitted(users_quadz, "mbox", bobo_sec)

      verify_create_denied(users_quadz, "spleen", quadz_sec)
      verify_create_denied(users_quadz, "spleen", pantaloons_sec)
      verify_create_denied(users_quadz, "spleen", bobo_sec)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      verify_unlink_denied(users_quadz_mbox, quadz_sec)
      verify_unlink_denied(users_quadz_mbox, pantaloons_sec)
      verify_unlink_denied(users_quadz_mbox, bobo_sec)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_r_0_r
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_r_0_r, perm_r_0_r, perm_r_0_r)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_permitted(users_quadz, quadz_sec)
      verify_reads_denied(users_quadz, pantaloons_sec)
      verify_reads_permitted(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_denied(users_quadz, quadz_sec)
      verify_writes_denied(users_quadz, pantaloons_sec)
      verify_writes_denied(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_permitted(users_quadz, quadz_sec)
      verify_parent_reads_denied(users_quadz, pantaloons_sec)
      verify_parent_reads_permitted(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_permitted(users_quadz, "mbox", quadz_sec)
      verify_child_reads_denied(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_permitted(users_quadz, "mbox", bobo_sec)

      verify_create_denied(users_quadz, "spleen", quadz_sec)
      verify_create_denied(users_quadz, "spleen", pantaloons_sec)
      verify_create_denied(users_quadz, "spleen", bobo_sec)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      verify_unlink_denied(users_quadz_mbox, quadz_sec)
      verify_unlink_denied(users_quadz_mbox, pantaloons_sec)
      verify_unlink_denied(users_quadz_mbox, bobo_sec)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_r_r_0
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_r_r_0, perm_r_r_0, perm_r_r_0)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_permitted(users_quadz, quadz_sec)
      verify_reads_permitted(users_quadz, pantaloons_sec)
      verify_reads_denied(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_denied(users_quadz, quadz_sec)
      verify_writes_denied(users_quadz, pantaloons_sec)
      verify_writes_denied(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_permitted(users_quadz, quadz_sec)
      verify_parent_reads_permitted(users_quadz, pantaloons_sec)
      verify_parent_reads_denied(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_permitted(users_quadz, "mbox", quadz_sec)
      verify_child_reads_permitted(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_denied(users_quadz, "mbox", bobo_sec)

      verify_create_denied(users_quadz, "spleen", quadz_sec)
      verify_create_denied(users_quadz, "spleen", pantaloons_sec)
      verify_create_denied(users_quadz, "spleen", bobo_sec)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      verify_unlink_denied(users_quadz_mbox, quadz_sec)
      verify_unlink_denied(users_quadz_mbox, pantaloons_sec)
      verify_unlink_denied(users_quadz_mbox, bobo_sec)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_w_w_w
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_denied(users_quadz, quadz_sec)
      verify_reads_denied(users_quadz, pantaloons_sec)
      verify_reads_denied(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_permitted(users_quadz, quadz_sec)
      verify_writes_permitted(users_quadz, pantaloons_sec)
      verify_writes_permitted(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_denied(users_quadz, quadz_sec)
      verify_parent_reads_denied(users_quadz, pantaloons_sec)
      verify_parent_reads_denied(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_denied(users_quadz, "mbox", quadz_sec)
      verify_child_reads_denied(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_denied(users_quadz, "mbox", bobo_sec)

      verify_create_permitted(users_quadz, "spleen", quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_create_permitted(users_quadz, "spleen", pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_create_permitted(users_quadz, "spleen", bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_unlink_permitted(users_quadz_mbox, quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_unlink_permitted(users_quadz_mbox, pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_unlink_permitted(users_quadz_mbox, bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_w, perm_w_w_w, perm_w_w_w)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_0_w_w
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_denied(users_quadz, quadz_sec)
      verify_reads_denied(users_quadz, pantaloons_sec)
      verify_reads_denied(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_denied(users_quadz, quadz_sec)
      verify_writes_permitted(users_quadz, pantaloons_sec)
      verify_writes_permitted(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_denied(users_quadz, quadz_sec)
      verify_parent_reads_denied(users_quadz, pantaloons_sec)
      verify_parent_reads_denied(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_denied(users_quadz, "mbox", quadz_sec)
      verify_child_reads_denied(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_denied(users_quadz, "mbox", bobo_sec)

      verify_create_denied(users_quadz, "spleen", quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_create_permitted(users_quadz, "spleen", pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_create_permitted(users_quadz, "spleen", bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_unlink_denied(users_quadz_mbox, quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_unlink_permitted(users_quadz_mbox, pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_unlink_permitted(users_quadz_mbox, bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_0_w_w, perm_0_w_w, perm_0_w_w)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_w_0_w
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_denied(users_quadz, quadz_sec)
      verify_reads_denied(users_quadz, pantaloons_sec)
      verify_reads_denied(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_permitted(users_quadz, quadz_sec)
      verify_writes_denied(users_quadz, pantaloons_sec)
      verify_writes_permitted(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_denied(users_quadz, quadz_sec)
      verify_parent_reads_denied(users_quadz, pantaloons_sec)
      verify_parent_reads_denied(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_denied(users_quadz, "mbox", quadz_sec)
      verify_child_reads_denied(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_denied(users_quadz, "mbox", bobo_sec)

      verify_create_permitted(users_quadz, "spleen", quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_create_denied(users_quadz, "spleen", pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_create_permitted(users_quadz, "spleen", bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_unlink_permitted(users_quadz_mbox, quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_unlink_denied(users_quadz_mbox, pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_unlink_permitted(users_quadz_mbox, bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_0_w, perm_w_0_w, perm_w_0_w)
      verify_unlink_permitted(users_quadz_mbox, root_sec)

      # test perm_w_w_0
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)

      verify_stat_permitted(users_quadz, root_sec)
      verify_stat_permitted(users_quadz, quadz_sec)
      verify_stat_permitted(users_quadz, pantaloons_sec)
      verify_stat_permitted(users_quadz, bobo_sec)

      verify_reads_permitted(users_quadz, root_sec)
      verify_reads_denied(users_quadz, quadz_sec)
      verify_reads_denied(users_quadz, pantaloons_sec)
      verify_reads_denied(users_quadz, bobo_sec)
      
      verify_writes_permitted(users_quadz, root_sec)
      verify_writes_permitted(users_quadz, quadz_sec)
      verify_writes_permitted(users_quadz, pantaloons_sec)
      verify_writes_denied(users_quadz, bobo_sec)

      verify_parent_reads_permitted(users_quadz, root_sec)
      verify_parent_reads_denied(users_quadz, quadz_sec)
      verify_parent_reads_denied(users_quadz, pantaloons_sec)
      verify_parent_reads_denied(users_quadz, bobo_sec)
      
      verify_child_reads_permitted(users_quadz, "mbox", root_sec)
      verify_child_reads_denied(users_quadz, "mbox", quadz_sec)
      verify_child_reads_denied(users_quadz, "mbox", pantaloons_sec)
      verify_child_reads_denied(users_quadz, "mbox", bobo_sec)

      verify_create_permitted(users_quadz, "spleen", quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_create_permitted(users_quadz, "spleen", pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_create_denied(users_quadz, "spleen", bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_create_permitted(users_quadz, "spleen", root_sec)

      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_unlink_permitted(users_quadz_mbox, quadz_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_unlink_permitted(users_quadz_mbox, pantaloons_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_unlink_denied(users_quadz_mbox, bobo_sec)
      root, users, users_quadz, users_quadz_mbox = *create_root_users_quadz_mbox(perm_w_w_0, perm_w_w_0, perm_w_w_0)
      verify_unlink_permitted(users_quadz_mbox, root_sec)
    end

    def create_root_users_quadz_mbox(users_perm, quadz_perm, mbox_perm)
      root_sec = UserSec.new(nil, [])
      root = DBNode.new("", [PERM::RW, PERM::R, PERM::R], nil, nil)
      users = root.create(["users"], users_perm, nil, nil, root_sec)
      users_quadz = root.create(%w(users quadz), quadz_perm, "quadz", "admin", root_sec)
      users_quadz_mbox = root.create(%w(users quadz mbox), mbox_perm, "quadz", "admin", root_sec)
      [root, users, users_quadz, users_quadz_mbox]
    end

    def verify_stat_permitted(node, sec)
      assert_nothing_raised { node.name }
      assert_nothing_raised { node.perm }
      assert_nothing_raised { node.owner }
      assert_nothing_raised { node.group }
    end
        
    def verify_reads_denied(node, sec)
      assert_raises(DBDB::PermissionDenied) { node.get(sec) }
      assert_raises(DBDB::PermissionDenied) { node.childlist(sec) }
    end

    def verify_reads_permitted(node, sec)
      assert_nothing_raised { node.get(sec) }
      assert_nothing_raised { node.childlist(sec) }
    end

    def verify_writes_denied(node, sec)
      assert_raises(DBDB::PermissionDenied) { node.set("spang", sec) }
      assert_raises(DBDB::PermissionDenied) { node.unset(sec) }
    end

    def verify_writes_permitted(node, sec)
      assert_nothing_raised { node.set("spang", sec) }
      assert_nothing_raised { node.unset(sec) }
    end
    
    def verify_parent_reads_denied(node, sec)
      assert_raises(DBDB::PermissionDenied) { node.parent(sec) }
      assert_raises(DBDB::PermissionDenied) { node.fetch([".."], sec) }
      assert_raises(DBDB::PermissionDenied) { node.exist?([".."], sec) }
    end

    def verify_parent_reads_permitted(node, sec)
      assert_nothing_raised { node.parent(sec) }
      assert_nothing_raised { node.fetch([".."], sec) }
      assert_nothing_raised { node.exist?([".."], sec) }
    end

    def verify_child_reads_denied(node, childname, sec)
      assert_raises(DBDB::PermissionDenied) { node.childlist(sec) }
      assert_raises(DBDB::PermissionDenied) { node.fetch([childname], sec) }
      assert_raises(DBDB::PermissionDenied) { node.exist?([childname], sec) }
    end

    def verify_child_reads_permitted(node, childname, sec)
      assert_nothing_raised { node.childlist(sec) }
      assert_nothing_raised { node.fetch([childname], sec) }
      assert_nothing_raised { node.exist?([childname], sec) }
    end

    def verify_create_denied(node, childname, sec)
      assert_raises(DBDB::PermissionDenied) { node.create([childname], DBDB::DEFAULT_PERM, nil, nil, sec) }
    end

    def verify_create_permitted(node, childname, sec)
      assert_nothing_raised { node.create([childname], DBDB::DEFAULT_PERM, nil, nil, sec) }
    end

    def verify_unlink_denied(node, sec)
      assert_raises(DBDB::PermissionDenied) { node.unlink(sec) }
    end

    def verify_unlink_permitted(node, sec)
      assert_nothing_raised { node.unlink(sec) }
    end
  end
  
  class TestDBDB < Test::Unit::TestCase

    #
    # 20/Nov/04
    # attacks vulnerable to:
    #   - user creates directory depth bomb - we use recursive
    #     node search, so we'd bomb with a stack overflow
    #     fix: ? enforce depth limit (?)
    #   - user creates files and dirs in a loop
    #     fix: quotas?  like maximum # total files? hm

    #
    # needs to work well for:
    #   map database
    #     map
    #       shortname, longname, implicit nextmap, default dmflags, 
    #       map "size"
    #       admin comments / notes
    #       admin rating
    #
    #   map rotation
    #     map rotation list
    #     admin map rotation favorites lists
    #     
    #
    #   db client settings/preferences
    #     username, passwd(crypted), perms, gender
    #     window sizes, windowed mode on/off
    #     chat / log filters, status win on/off
    #
    #   botter info repository
    #     botter nickname
    #       "assblaster", all known IPs, bots used, comments
    #       admin comments / notes
    #
    #   admin mailboxes, leaving notes for other admins
    #   global mailbox, leaving notes for all
    #
    #   help, command registry ???
    #
    # needs permissions/security... can't read/write other
    # admins settings/preferences area, for inst
    #
    # transactions/undo ????????????    
    #
    # symlinks - there have to be symlinks - it's a proven fact that
    # systems without symlinks suck
    #
    # regarding  caching in DBAccessor - if database sets a
    # dirty flag on rename and move operations, things that
    # would invalidate a path to any node (potentially, conservative algo)
    # - then, accessors (DBAccessor instances) should be
    # able to cache node its clients are using, for quick access
    #
    # extrapolating, changing user/group info (?) should set database
    # dirty bit?   or no, because user/group [membergroups] passed in
    
    # if/given all user/group knowledge of where user group info is *stored*
    # (talking about /users/... and /groups/...) is external to the
    # database itself (as it is currently), --- possible benefit of
    # database users being able to query the root of some tree they're
    # insterested in, and ask if anything's changed [since they last
    # checked--timestamp] 
    # so then we could ask, did anything in groups <dir> change ?
    # we might cache the user's group-memberlist until such time as
    # anything in the groups dir changed
    
    def test_create_users_perms
      db = DBDB.new
      
      # "root" user (nil), member-groups (nil)
      dbac = DBAccessor.new(db, nil, [])

      assert_equal( DBDB::DEFAULT_PERM, dbac.perm("/") )

      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::R], dbac.defperm )
      dbac.defperm = [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE]
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.defperm )

      assert_equal( "/", dbac.pwd )
      assert_equal( [], dbac.dir )
      
      # although "set" will create the specified leaf node if necessary,
      # "get" and "unset" should not
      assert_nil( dbac.get("bogus") )
      assert_equal( [], dbac.dir )
      dbac.unset "bogus"
      assert_equal( [], dbac.dir )

      # test get and set on the root (was a bug)
      dbac.set "/", "kazoo"
      assert_equal( "kazoo", dbac.get("/") )
      dbac.unset "/"
      assert_nil( dbac.get("/") )

      dbac.create "users"
      assert_equal( ["users"], dbac.dir )
      assert_nil( dbac.owner("users") )
      assert_nil( dbac.group("users") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.perm("users") )

      dbac.cd "users"
      assert_equal( "/users", dbac.pwd )

      dbac.create "quadz"
      dbac.cd "quadz"
      assert_equal( "/users/quadz", dbac.pwd )
      dbac.set "passwd", "WaxF5Q1o3FJx6"
      assert_equal( "WaxF5Q1o3FJx6", dbac.get("/users/quadz/passwd") )
      dbac.set "dbperm", "010101010"
      assert_equal( "010101010", dbac.get("/users/quadz/dbperm") )
      # hmmmm... /users/quadz/tty bad name, cause multiple quadz can log in
      
     # dbac.create "/users/quadz/tty"
     # dbac.setdev "tty", Object.new  # todo: symlink to /dev/socket/client4
     #     # so that writing to tty, then,

      dbac.create "../pantaloons"
      dbac.create "../bobothechimp"
      assert_equal( %w(bobothechimp pantaloons quadz), dbac.dir("/users") )
      assert_equal( %w(bobothechimp pantaloons quadz), dbac.dir("..") )

      dbac.cd ".."
      assert_equal( "/users", dbac.pwd )

      assert_nil( dbac.owner("quadz") )
      assert_nil( dbac.group("quadz") )
      assert_nil( dbac.owner("quadz/passwd") )
      assert_nil( dbac.group("quadz/passwd") )
      assert_nil( dbac.owner("quadz/dbperm") )
      assert_nil( dbac.group("quadz/dbperm") )

      dbac.setowner "./quadz", "quadzzz"
      assert_equal( "quadzzz", dbac.owner("./quadz") )
      dbac.setgroup "./quadz", "quadzgg"
      assert_equal( "quadzgg", dbac.group("./quadz") )
      assert_nil( dbac.owner("quadz/passwd") )
      assert_nil( dbac.group("quadz/passwd") )
      assert_nil( dbac.owner("quadz/dbperm") )
      assert_nil( dbac.group("quadz/dbperm") )

      dbac.setowner_r "./quadz", "quadz"
      assert_equal( "quadz", dbac.owner("quadz") )
      assert_equal( "quadzgg", dbac.group("quadz") )
      assert_equal( "quadz", dbac.owner("quadz/passwd") )
      assert_nil( dbac.group("quadz/passwd") )
      assert_equal( "quadz", dbac.owner("quadz/dbperm") )
      assert_nil( dbac.group("quadz/dbperm") )

      dbac.setgroup_r "./quadz", "quadx"
      assert_equal( "quadz", dbac.owner("quadz") )
      assert_equal( "quadx", dbac.group("quadz") )
      assert_equal( "quadz", dbac.owner("quadz/passwd") )
      assert_equal( "quadx", dbac.group("quadz/passwd") )
      assert_equal( "quadz", dbac.owner("quadz/dbperm") )
      assert_equal( "quadx", dbac.group("quadz/dbperm") )

      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.perm("quadz") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.perm("quadz/passwd") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.perm("quadz/dbperm") )

      dbac.setperm "./quadz", [DBDB::PERM::R, DBDB::PERM::NONE, DBDB::PERM::NONE]
      assert_equal( [DBDB::PERM::R, DBDB::PERM::NONE, DBDB::PERM::NONE], dbac.perm("quadz") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.perm("quadz/passwd") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::R, DBDB::PERM::NONE], dbac.perm("quadz/dbperm") )
      
      dbac.setperm_r "./quadz", [DBDB::PERM::RW, DBDB::PERM::NONE, DBDB::PERM::NONE]
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::NONE, DBDB::PERM::NONE], dbac.perm("quadz") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::NONE, DBDB::PERM::NONE], dbac.perm("quadz/passwd") )
      assert_equal( [DBDB::PERM::RW, DBDB::PERM::NONE, DBDB::PERM::NONE], dbac.perm("quadz/dbperm") )

      dbac.create "/groups/admin"
      assert_equal( nil, dbac.get("/groups/admin") )
      assert_equal( [], dbac.get("/groups/admin", []) )  # supply default
      dbac.set("/groups/admin", dbac.get("/groups/admin", []).push("quadz") )
      assert_equal( %w(quadz), dbac.get("/groups/admin") )
      dbac.set("/groups/admin", dbac.get("/groups/admin").push("pantaloons") )
      assert_equal( %w(quadz pantaloons), dbac.get("/groups/admin") )

      dbac.create "/groups/devel"
      dbac.set "/groups/devel", %w(quadz pantaloons)
      assert_equal( %w(quadz pantaloons), dbac.get("/groups/devel") )

      db.close      
    end

    def test_create_mapdef
      db = DBDB.new
      
      # "root" user (nil), member-groups (nil)
      dbac = DBAccessor.new(db, nil, [])

      assert_equal( "/", dbac.pwd )
      assert_equal( [], dbac.dir )
      dbac.create "mapdef/city1"  # create object path if doesn't exist
      assert_equal( ["mapdef"], dbac.dir )
      assert_equal( ["city1"], dbac.dir("mapdef") )
      assert_nil( dbac.get("mapdef/city1/longname") )
      dbac.set "mapdef/city1/longname", "Outer Courts"
      assert_equal( "Outer Courts", dbac.get("mapdef/city1/longname") )
      dbac.cd "mapdef"
      dbac.set "city1/dmflags", "-fd +a -pu"
      assert_equal( "-fd +a -pu", dbac.get("city1/dmflags") )
      dbac.cd "city1"
      assert_equal( "/mapdef/city1", dbac.pwd )
      dbac.set "nextmap", "city2"
      assert_equal( "city2", dbac.get("nextmap") )
      dbac.set "playsize", "3.5"  # out of 5 :)
      dbac.set "filesize", "0"  # built-in
      assert_equal( %w(dmflags filesize longname nextmap playsize), dbac.dir )  # sorted alpha
      
      # create works like mkdir -p ... but set won't create a path for you
      assert_raises(DBDB::PathNotFound) { dbac.set "rating/quadz", "4.5" }
      # likewise, get complains if path not found (unless it's the
      # last component that's not found, in which case, get returns nil)
      assert_raises(DBDB::PathNotFound) { dbac.get "rating/quadz" }

      dbac.create "rating"
      assert_nothing_raised { dbac.set "rating/quadz", "4.5" }
      assert_equal( "4.5", dbac.get("rating/quadz") )
      # get returns nil when last component from which we're fetching is not found
      # this is to be symmetrical with set, which can create leaf nodes without
      # doing a create
      assert_nil( dbac.get("rating/blahblah") )

      # rating should show up in the dir with all the attrs
      assert_equal( %w(dmflags filesize longname nextmap playsize rating), dbac.dir )

      # rating has no attr set, so, should not show up in attrs list      
      assert_equal( %w(dmflags filesize longname nextmap playsize), dbac.attrs )

      # try clearing an attr
      dbac.unset "nextmap"
      assert_nil( dbac.get("nextmap") )
      # should be missing from attrs
      assert_equal( %w(dmflags filesize longname playsize), dbac.attrs )
      # but still present in dir
      assert_equal( %w(dmflags filesize longname nextmap playsize rating), dbac.dir )

      # now delete it
      dbac.delete "nextmap"
      assert_equal( %w(dmflags filesize longname playsize rating), dbac.dir )

      db.close      
    end

    TEST_DB_FNAME = "test_db.dat"

    class TestUndumped
      include DBDB::Undumped
      attr_reader :blah
      def initialize
        @blah = "huzzah!"
      end
    end

    def test_load_store
      File.delete TEST_DB_FNAME if File.exist? TEST_DB_FNAME

      db = DBDB.new
      dbac = DBAccessor.new(db, nil, [])

      dbac.create "/mapdef/city1"
      dbac.set "mapdef/city1/longname", "Outer Courts"
      dbac.create "/sv/xquake/status"
      dbac.set "/sv/xquake/rcon", TestUndumped.new
      assert_equal( "huzzah!", dbac.get("/sv/xquake/rcon").blah )
      
      verify_parent_links(db)

      assert( ! File.exist?(TEST_DB_FNAME) )
      db.store TEST_DB_FNAME
      assert( File.exist?(TEST_DB_FNAME) )
      
      db = DBDB.load TEST_DB_FNAME
      dbac = DBAccessor.new(db, nil, [])
    
      verify_parent_links(db)
      
      assert_equal( "Outer Courts", dbac.get("/mapdef/city1/longname") )
      assert_nil( dbac.get("/sv/xquake/rcon") )
    end

    def verify_parent_links(db)
      sec = UserSec.new(nil, [])
      root = db.fetch("/", sec)
      root.each do |node|
        node.childlist(sec).each do |child|
          assert_equal( node.object_id, child.parent(sec).object_id, "par=(#{node.mypathstr}) kid=(#{child.mypathstr})" )
        end
      end
    end

    def test_keybind_to_cmd
      # bind is just a program that makes a relationship between
      # a key and some command (in dbdb) and either a symlink
      # or a property
      # 
      #   bind c-w /cmd/win on
      #   
      #     *and bind itself is a prog (/cmd/bind or whatever)
      #      that just does (for ex.) 
      #        #!/cmd/sh
      #        link /cmd/winmode ~user/bind/c-w
      #        -or-
      #        link /cmd/win-toggle ~user/bind/c-w
      #
      #     or
      #       alias 
      #       bindalias c-a "/cmd/win on"
      #       bind c-a "/cmd/win on ; show-status-in-dyn"
      #       
    end
    
    def test_query_path_passed_to_command_handler
      # dbac.query("/users/quadz/handle-it/and/a/path", "findit")
      # that is, if the handler were installed at "handle-it"
      # then that handler would be called, but still
      # get passed the handle-it/and/a/path
    end
    
    def test_delayed_privmsg
      # in this case, who provides the "send" functionality?
      # dbac.update("/users/quadz/inbox", "send", "[date/time] from fluff: Yerf!")
      #
      # if agents/droids could register/link into a
      # database node to provide queries
      # ...
      # NB.. there's no reason any query couldn't provide
      # tuplespace equiv. verbs as appropriate
      #
      # if it WAS a tuplespace
    end
    
    def test_key_bound_windowconfig
      # users presses key, either entire windowconfig
      # changes to new "desktop" ... hmm! like in X win managers
      # if we provide basic keys for window management
      # hm!
      # cmd("/users/quadz/desktop/1", "new_window", "12", "25")  
      #
      # quadz_desktop = create("/users/quadz/desktop")
      # 
      # touch /users/quadz/desktop
      # /users/quadz/desktop.set_handler /lib/DesktopHandler
      # 
      # chlib /users/quadz/desktop /lib/DesktopHandler
      #
      # set /users/quadz/desktop /lib/DesktopHandler
      # /users/quadz/desktop windef 12 25
      #
      # cd /users/quadz/desktop
      # status_win
      #
      # cd /users/quadz/windef
      # status = /lib/Window
      # status/top = 12 ; status/bottom = 25
      #
      # status/content = /lib/
      #
      # ../quadz/desktop = /lib/DesktopHandler
      # ../desktop/hideall
      # ../desktop/show ../windef/status
      # 
      #
      # status = (/lib/NewWindow)
      
      # /render/status /users/quadz/win/status 

      # cd /users/quadz/windef
      # status = /lib/NewWindow
      # status/drawproc = /disp/status
      #
      # ../quadz/desktop = /lib/DesktopHandler
      # ../desktop hideall
      # ../desktop show ../windef/status
      
    end

    def eventual_test_data_procfilter_pipe
      # thought was in plug-in mp3 decoder
      # as for example: mp3 is patented, but
      # that shouldn't stop a user from
      # connecting a plug-in that can transform
      # data
    end

    def eventual_test_mount_network_fs_mapper
      # mount "real" portions of a filesystem,
      # either some part of localhost, or 
      # networked, where operations on nodes
      # map directly to files on the filesystem
      #  - can eventually map FTP and SFTP services
      #    in as well virtually
    end
    
    def eventual_test_query_policy
      # assert_equal( <<-"ENDTXT", dbac.query("/admin/policy", "privacy") )
      #   policy on private messages not being logged
      #   etc.
      #   
      #   communication is rare
      # ENDTXT   
    end
    
    def test_server_config
      # directory entries representing settings
      # sent to server by "fluff" or "hal" or "db"
      # when server crashes, etc.
      # dbac.set "servers/xquake/init/spawn_prot", "rcon tune_spawn_prot 1.0"
    end

    def test_user_keybindings
      # dbac.create "/users/quadz/binds/", true  # true=>cd into it
      # dbac.set "c-a", "dyn-moveup"
      # OR
      # dbac.set "c-a", "/dev/win/dyn/cmd/moveup"
      # OR
      # "dyn-moveup" should be a command aliased to
      # (a built-in alias) /dev/win/dyn/cmd/moveup
      # OR
      # dbac.set "c-a", "tell /dev/win/dyn moveup"
    end  

    def test_open_read_write
      # handle = dbac.open "/dev/tty/client078a"
      # handle.print "cazart!"
    end

    def eventual_test_scp_filesystem_links
      # and ftp:// and http: links as well
      # link directly to an scp file or dir on remote system
      # ...
      # i guess first pass, can't get directory listings in
      # these systems, but we could for ftp.. and maybe scp
      # depending on if we can just do whatever sftp would do
      #
      # can also say:
      # symlink scp://quake2@tastyspleen.net/bobo/checkthis.mp3 /users/bobo/rad.mp3
    end

    # db-screen addrssable by database interface
    # 
    # dev/screen
    # dev/window/12,25/rows[]
    #                 /cursor[]
    #                 
    #   ?
    #
    # dev/window/12,25/rows[]   
    #           /dyn/          (dyn a symlink to 12,25 ??)
    #
    # like if you go:
    def eventual_test_dev_window
      @dbac.cd "/dev/window/rgn"
      assert_equal( %w(01,11 12,25 26,26 27,47), @dbac.dir )
      
      @dbac.delete "/dev/window/rgn/12,25"   # rgn disappears, others below uncovered or expand to fill gap
      
      @dbac.rename "/dev/window/rgn/12,25", "/dev/window/rgn/12,23"  # window resizes !??!

      ############ or......
      
      # just use names, we can examine their sizes by property fetch
      @dbac.cd "/dev/window"
      assert_equal( %w(log info dyn chat input), @dbac.dir )
      # this like a latch, tuplespace like, dev/window controller
      # is there waiting for its object to be written to
      # like /dev/dsp /dev/random in linux... 
      # when we write to adjustbottom's property, this can be
      # set on an object set as the custom controller for that
      # node, which will take action appropriately
      @dbac.set("/dev/window/dyn/adjustbottom", "-2")  # shrink 
    end
     
    def eventual_test_tty
      # these come and go as client connections are accepted
      # maybe, like pids, they count up so they are not easily
      # accidentally reused by errant code with old data
      dbac.create "/dev/socket/client/1"
      dbac.create "/dev/socket/client/2"
      # ...
      dbac.create "/dev/socket/client/473"
      # ...
      # or maybe we just reuse the first avail..whatever...
      
      # so, agents should be sent, in addition to
      # client name, (speaker/admin name), should also
      # get client number, so agent can talk directly
      # to that client back privately
      #
      # whereas humans doing privmsg to another admin,
      # might just want to wall all of their ttys..
      # if bobo is logged in 3 times, and you want to
      # privmsg bobo, should prolly go to all bobo's sessions
      
    end

    def eventual_test_admin_homepage
                      
    end               
                      
    def eventual_test_db_bug_reporting_graph
      # graph meaning database tree
      # or what needed to store data for
      # a "bug reporting" homepage and
      # entry ability
      
      # "enter"
      # "talk about"
      # (about)
      #####
      # some annotation mechanism, in
      # tree form with links
      # -- some way to mention a
      # bug / add a bug on the main
      # homepage... either we go to the
      # discussion subpage about that
      # bug.... maybe a 1 to 10 scale
      # of 
    end

    def test_normalized_mapdef_map_rating
      # so chatt can have 10 star rating
      # or his pref. and i could have 5 star
      # rating with floating point --- the
      # *view* is selectable
    end

    def test_settingdisplay_ips_reverse_dns
      # some /users/u/settings/display/status/ips_dns = "true"
      # deal... but...
      # wanting user vocab
      # pritives.. user can "talk about" status ips, and the
      # ips on the status region hilight indicating db has
      # understood, or it's db's best guess
      # user:
      #    @ status
      #    @ status ips
      #    @ status ips off
      
      # when we do @, input should jump up to the cyan/white 
      # prompt - or at least change prompt "shell" accept
      # dbcommand input (live search refinement) then return
      # seamlessly to what was being typed
      
    end

    def test_user_keybinding
      # bind c-a
      # set ~/keymap/c-a "menu_search"
      # alias menu_search "load /menu/search in /win/dyn"
      # alias menu_search "/menu/search > /win/dyn"
      # alias menu_search "attach /menu/search to /win/dyn"
      # alias menu_search "/menu/search --> /win/dyn"
      #
      # This could be as simple as /menu/search is the
      # program, and /win/dyn is its argument, which it
      # interprets as the devicename for a window to connect to:
      # alias menu_search "/menu/search /win/dyn &"
    end

    def test_playername_index
      # /dev/playername/
      #
      # paths / the path split that happens in db layer
      # at least, and path strings generated by nodes, etc...
      # need to be able to escape spaces and even slashes
      # any character in the player name must be a legal
      # path name... could just use CGI escape notation if
      # necessary... 
      #
      # /player/names/Foo[{}~/\/\foo
      # is yucky....  ... escaped?
      #   LEGAL_FILENAME_CHARSET = "A-Za-z0-9_%: ... hmmmm
      #   gsub(/[^A-Za-z0-9_]/) {|ch| sprintf("\%%02x", ch[0]) }
      #
      # "Foo%5b%7b%7d%7e%2f%5c%2f%5cfoo"
      #
      # nasty
      # UNLESS the dbaccessor transparently hid all that
      # but NO, problem is, users can't type ungarbled names at shell
      # without path escaping legal filename chars nightmare
      #
      # /player/names.search('Foo[{}~/\/\foo')
      # yuck
      #
      # assert_equal( ['Foo[{}~/\/\foo', 'Foo[{}~/\/\foo2'], cmd("/player/names", "find", 'Foo[{}~/\/\foo')
      # assert_equal( ['Foo[{}~/\/\foo', 'Foo[{}~/\/\foo2'], cmd("/player/names/search", 'Foo[{}~/\/\foo')
      # assert_equal( ['Foo[{}~/\/\foo', 'Foo[{}~/\/\foo2'], cmd("/players/find", 'Foo[{}~/\/\foo')
      # assert_equal( ['Foo[{}~/\/\foo', 'Foo[{}~/\/\foo2'], cmd("/find/player", 'Foo[{}~/\/\foo')
      #
      # /player/person/pops
      # /player/person/sicker  [way to reference IP group, ties
      #                         together all IPs we've catalogued
      #                         as owned by this person... someday
      #                         may want to further classify that 
      #                         into time ranges, like two years ago
      #                         from feb to aug this IP was/should
      #                         be a member of person/sicker - but
      #                         recently a new player was assigned
      #                         that ip, so now that ip is included
      #                         in /person/bobothechimp

      
      # but as for the {agent, mech, droid} shell != same as user shell
      # transmit encoded ruby objects
      # so cmd("/dir", *args) just direct invocation with necessary encoding
      # for line-based shell format
      #
      # But at is core a DBAccessor method      
      #
      # have to un-marshal objects (from the 'droid' 'ai'?) 
      # in a thread at $SAFE == 4 ? and return the object
      # itself as tainted?
      
    end

    def eventual_test_dev_sound
      # dorkbuster - pretz / apple want to play sound,
      # or hal, whatever, at certain volume
      # so: /dev/sound have anything going for it in db?
      #
      # then play verb could be
      # implemented in terms of a device call, filesystem
      # write.... any point?
      #   echo 
    end
   
    def eventual_test_speak_cmd_verb_to_node
      # cmd("/dev/sound", "play spock1 loud")
      # So each device has a "port" for
      #
      # using /dev/sound   [OK]
      # (adds in /mixes that device vocab into your
      # context ((most-recent)))
      # (can forget /dev/sound or whatever verb as well to unmix)
      # unmix/remove/unuse/zap/(wordnet?)  ... provide
      # aliases, optionally collect metrics/feedback on
      # user's preferred term for resolving ambiguities
      # to a level of confidence
      

      # 22:09:38 pretz: The only reason I was messing with it is to try to learn a few things about how the maps are changed for customs.
      # 22:10:05 pretz: My observations are that there's too much of one bot depending on another and no error checking...
      # so -
      # using /dev/playmap
      # play beware the pit next     # => cmd("/dev/playmap", "beware the pit")
      #                              # 
      # 
      
      # cmd("/dev/sound", "play spock1 loud")
      # cmd("/dev/playmap", "beware the pit")
      # read("/dev/sound/playlist") === []
      #                            like %w(base1 q2pitnew base2)
      # 
    end

    # Any advantage to having stuff for a node's set/get
    # be stored in a tuplespace.  Could be a global
    # tuplespace if we prepended our path name (provided
    # we can handle renames).  Like, our global tuples
    # could be:  [ "/usr/spleen/keymap", :bind, "c-a", "menu_search" ]
    # The first param being the patho of the node to which
    # this tuple was written.


    # set defaults for 
    # remove pwsnskle
    #   - how could database be presented such that we could
    #     implement pwsnslke remove, uh - easily ? with some
    #     database structured commands, 
    #       cd /dict/pwsnskle
    #         ^ now, you may be in a 'virtual' directory
    #           space... or with the object representing
    #           this dir extending some base object to
    #           provide ... hmm
    #       cd /dict
    #       dir pwsnskle
    #       i guess i'm wanting a different space, in
    #       leaf nodes, that .... maybe inputting a 
    #       "cmd" to a node.... some way to issue
    #       commands to the node... uh... 
    #       /dict/search  *search being predefined
    #       node so anything ... 
    #       cd /dict/search
    #       cd /dict
    #       ?\C-s
    #       ----
    #       cd /search
    #       info pwsnskle
    #       (or maybe just: pwsnskle alone - would get default info for object)
    #       =>"pwsnskle is a q2admin phenonema, we should remove it / filter it"
    #       cd /dev/dict    (devel perm / )
    #       cd remove 
    #       cd /dev/ips
    #       cd /dev/names
    #       cd /dev/akas
    #       purge pwsnskle
    #       ^^^^^^^ Here, /dev/akas is shown to have provided vocabulary
    #               ("commands, maybe ./cmd is in the default command search path)
    #               /dev/akas perhaps as simply as is added to the head of
    #               the search path for commands, and if it supplies some,
    #               which it does like "purge" - simplistic vocab impl.
    #       so the challenge is: we have to solve the problem anyway,
    #       removing pwsnskle from the database... why not make that
    #       a command so anyone adminning db can do it, start adding
    #       vocab
    #       cd /db/playernames     [auto-complete, tab-complete, ...?]
    #       cd /db/playernames
    #       info pwsnskle
    #       =>"pwsnskle first appeared 12/3/02, last seen 12 minutes ago on 12.34.56.78"
    #       =>"pwsnskle is associated with 134 different IP addresses"
    #       delete pwsnskle
    #       =>"PERMANENTLY DELETE /db/playernames/pwsnskle ?  
  
  end
end



