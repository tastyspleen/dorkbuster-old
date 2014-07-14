
require 'sqlite3'
require 'og'
require 'player_ip_stats_model'

require 'test/unit'


# do_create = ARGV.include? "-create"

$DBG = true


def bmsimple(n=1)
  before = Time.now
  n.times {|i| yield(i)}
  after = Time.now
  $stderr.puts "\n#{n} iterations in #{after-before} seconds."
end

class TestModel < Test::Unit::TestCase # :nodoc: all

  include PlayerIPStats

  def init_db_temp
    if PLATFORM =~ /linux/
      @db = Og.setup(
        :destroy => true,
        :store => :postgresql,
        :name => 'test-stats',
        :user => 'dorkbuster'
      )
    else
      @db = Og.setup(
        :destroy => true,
        :store => :sqlite,
        :name => 'test-stats'
      )
    end

    PlayerIPStats.create_all_indices
  end

  def init_db_perm
    @db = Og.setup(
      :destroy => false,
      :store => :sqlite,
      :name => 'test-stats-large'
    )
    
    PlayerIPStats.create_all_indices
  end

  def test_log_fragstats
    init_db_temp
    $DBG = false
    ttl = PlayerIPStats::STATS_TOTAL_NAME
    n = 1
    print "Frags......"
    bmsimple(n) {|i| print "#{i}..."
      PlayerIPStats.log_frag("wolf", "sheep", "rl", "mutant")
      PlayerIPStats.log_frag("wolf", "sheep", "rl", "mutant")
      PlayerIPStats.log_frag("wolf", "sheep", "rl", "mutant")
      PlayerIPStats.log_frag("wolf", "sheep", "cg", "mutant")
      PlayerIPStats.log_frag("wolf", "sheep", "cg", "mutant")
      PlayerIPStats.log_frag("wolf", "sheep", "rl", "vanilla")
      PlayerIPStats.log_frag("wolf", "sheep", "gl", "vanilla")
      PlayerIPStats.log_frag("wolf", "sheep", "cg", "vanilla")
      PlayerIPStats.log_frag("sheep", "wolf", "rl", "vanilla")
      PlayerIPStats.log_frag("sheep", "wolf", "cg", "vanilla")
    }
    print "Suicides......"
    bmsimple(n) {|i| print "#{i}..."
      PlayerIPStats.log_suicide("sheep", "rl", "mutant")
      PlayerIPStats.log_suicide("sheep", "crater", "mutant")
      PlayerIPStats.log_suicide("sheep", "lava", "mutant")
      PlayerIPStats.log_suicide("wolf", "rl", "mutant")
      PlayerIPStats.log_suicide("wolf", "gl", "mutant")
      PlayerIPStats.log_suicide("sheep", "rl", "vanilla")
      PlayerIPStats.log_suicide("sheep", "crater", "vanilla")
      PlayerIPStats.log_suicide("sheep", "lava", "vanilla")
      PlayerIPStats.log_suicide("wolf", "rl", "vanilla")
      PlayerIPStats.log_suicide("wolf", "gl", "vanilla")
    }
    print "Queries......"
    
    puts
    
    puts( FragsAllTime.top_frags_list("wolf", nil, ttl,  nil,      Date.today, nil).inspect )
    puts( FragsAllTime.top_frags_list("wolf", nil, ttl, ttl,      Date.today, nil).inspect )
    puts( FragsAllTime.top_frags_list("wolf", nil, nil,  "vanilla", Date.today, nil).inspect )
    puts( FragsAllTime.top_frags_list("wolf", nil, ttl, "vanilla", Date.today, nil).inspect )
    puts( FragsAllTime.top_frags_list("wolf", nil, "cg", "vanilla", Date.today, nil).inspect )

    exit    

    bmsimple(n) {|i| print "#{i}..."
      assert_equal( 10*n, FragsAllTime.total_frags(ttl, ttl, ttl, ttl) )
      assert_equal(  8*n, FragsAllTime.total_frags("wolf", ttl, ttl, ttl) )
      assert_equal(  2*n, FragsAllTime.total_frags("sheep", ttl, ttl, ttl) )
      assert_equal(  2*n, FragsAllTime.total_frags(ttl, "wolf", ttl, ttl) )
      assert_equal(  8*n, FragsAllTime.total_frags(ttl, "sheep", ttl, ttl) )
      assert_equal(  5*n, FragsAllTime.total_frags(ttl, ttl, ttl, "mutant") )
      assert_equal(  5*n, FragsAllTime.total_frags(ttl, ttl, ttl, "vanilla") )
      assert_equal(  3*n, FragsAllTime.total_frags(ttl, ttl, "rl", "mutant") )
      assert_equal(  2*n, FragsAllTime.total_frags(ttl, ttl, "rl", "vanilla") )
      assert_equal(  4*n, FragsAllTime.total_frags(ttl, ttl, "cg", ttl) )
      assert_equal( 10*n, SuicidesAllTime.total_suicides(ttl, ttl, ttl) )
      assert_equal(  4*n, SuicidesAllTime.total_suicides("wolf", ttl, ttl) )
      assert_equal(  6*n, SuicidesAllTime.total_suicides("sheep", ttl, ttl) )
      assert_equal(  5*n, SuicidesAllTime.total_suicides(ttl, ttl, "mutant") )
      assert_equal(  5*n, SuicidesAllTime.total_suicides(ttl, ttl, "vanilla") )
      assert_equal(  2*n, SuicidesAllTime.total_suicides(ttl, "rl", "mutant") )
      assert_equal(  2*n, SuicidesAllTime.total_suicides(ttl, "rl", "vanilla") )
      assert_equal(  2*n, SuicidesAllTime.total_suicides("sheep", "crater", ttl) )
      assert_equal(  1*n, SuicidesAllTime.total_suicides("wolf", "gl", "vanilla") )
    }
  end

  def xxx_test_playerseen_grep
    init_db_perm
    rows = PlayerSeen.grep("bupk", 40)
    rows.each {|row| p row}
  end

  def xxx_test_find_playerseen
    init_db_perm

    # rows = PlayerSeen.find(:sql => "SELECT * FROM #{PlayerSeen.table} WHERE oid=1")
    # rows = Servername.find(:sql => "SELECT servername FROM #{Servername.table} WHERE servername LIKE '%muys%'")
    # rows = Servername.ogstore.query("SELECT servername FROM #{Servername.table} WHERE servername LIKE '%muys%'")
    sql =
      "SELECT #{Playername.table}.playername, #{Servername.table}.servername, "+
      "#{IPHost.table}.ip, #{IPHost.table}.hostname, "+
      "#{PlayerSeen.table}.first_seen, #{PlayerSeen.table}.last_seen, #{PlayerSeen.table}.times_seen "+
      "FROM #{PlayerSeen.table} LEFT JOIN #{IPHost.table} ON #{PlayerSeen.table}.iphost_oid = #{IPHost.table}.oid "+
      "LEFT JOIN #{Playername.table} ON #{PlayerSeen.table}.playername_oid = #{Playername.table}.oid "+
      "LEFT JOIN #{Servername.table} ON #{PlayerSeen.table}.servername_oid = #{Servername.table}.oid "+
      "WHERE #{Servername.table}.servername LIKE '%muys%' LIMIT 10"
    p sql
    rows = PlayerSeen.ogstore.query(sql)
    # p rows
    # p rows.class.ancestors
    # p rows.methods(false).sort
    # rows.each_row {|row,dummy| p row}
    rows.each_row {|row,dummy| p(row,row.map{|o|o.class}) }
  end

  def xxx_test_log_playerseen
    init_db_temp
    
    playername = "bupkis"
    ip = "67.19.248.74"
    hostname = "4a.f8.1343.static.theplanet.com"
    servername = "mutant"
    timestamp = Time.now
    PlayerSeen.log_player_seen(playername, ip, hostname, servername, timestamp)
    
    $DBG = false

    niter = 1000

    $stderr.puts "logging #{niter} different playerseen..."
    pn_x, ip_x, host_x, sv_x = playername.dup, ip.dup, hostname.dup, servername.dup
    bmsimple(niter) do |i|
      timestamp = Time.now
      PlayerSeen.log_player_seen(pn_x, ip_x, host_x, sv_x, timestamp)
      
      $stderr.print "#{i} " if i % 100 == 0
      pn_x.succ!
      ip_x.succ!
      host_x.succ!
      sv_x.succ!
    end

    $stderr.puts
    $stderr.puts "logging #{niter} repeat playerseen..."
    pn_x, ip_x, host_x, sv_x = playername.dup, ip.dup, hostname.dup, servername.dup
    bmsimple(niter) do |i|
      timestamp = Time.now
      PlayerSeen.log_player_seen(pn_x, ip_x, host_x, sv_x, timestamp)

      $stderr.print "#{i} " if i % 100 == 0
      pn_x.succ!
      ip_x.succ!
      host_x.succ!
      sv_x.succ!
    end
  end

  def xxx_test_something
    init_db
    ip = "67.19.248.74"
    hostname = "4a.f8.1343.static.theplanet.com"
    iphost = IPHost.find_or_create_by_ip_and_host(ip, hostname)
    iphost2 = IPHost.find_or_create_by_ip_and_host(ip, hostname)
    assert_equal( iphost.oid, iphost2.oid )
  end
end




# FROM: test/og/tc_relation.rb
#
#   def test_refers_to
#     # test refers_to accessor is correctly updated
#     u = User.create("George")
#     a = Article.create("Og is a good thing!")
#     assert_equal(nil, a.active_user)
# 
#     a.active_user = u
#     a.save!
#     assert_equal(u.oid, a.active_user_oid)
# #   assert_equal(u.object_id, a.active_user.object_id)
# 
#     u2 = User.create("Another user")
#     a.active_user = u2
#     a.save!
#     assert_equal(u2.oid, a.active_user_oid)
# 
#     # Note! Og doesn't automatically reload object referred by active_user
#     # so this won't equal.
#     assert_not_equal(u2.object_id, a.active_user.object_id)
# 
#     # Even forced reload won't help here as it won't reload relations.
#     a.reload
#     assert_not_equal(u2.object_id, a.active_user.object_id)
# 
#     # But forcing enchanted accessor to reload in refers_to.rb helps!
#     a.active_user(true)
#     # assert_equal(u2.object_id, a.active_user.object_id)
#     # and just to be sure oids are still correct
#     assert_equal(u2.oid, a.active_user_oid)
#   end


# tc_ez.rb:    users = User.find do |user|
# tc_ez.rb:    users = User.find { |user| user.age === [14, 23] }
# tc_ez.rb:      results = Musician.find {|m| m.kids === [3,4,5]}
# tc_ez.rb:        :true => Animal.find{|animal| animal.mammal! == :null }.map{|a| a.oid},
# tc_ez.rb:        :false => Animal.find{|animal| animal.mammal == :null }.map{|a| a.oid}
# tc_finder.rb:    User.find_by_name('tml')
# tc_finder.rb:    User.find_by_name_and_age('tml', 3)
# tc_finder.rb:    User.find_all_by_name_and_age('tml', 3)
# tc_finder.rb:    User.find_all_by_name_and_age('tml', 3, :name_op => 'LIKE', :age_op => '>', :limit => 4)
# tc_finder.rb:    User.find_or_create_by_name_and_age('tml', 3)
# tc_finder.rb:    User.find_or_create_by_name_and_age('stella', 5)
# tc_finder.rb:    User.find_or_create_by_name_and_age('tml', 3)
# tc_finder.rb:    u = User.find_by_name('tml')
# tc_finder.rb:    u2 = User.find_or_create_by_name_and_age('tommy', 9) {|x| x.father = 'jack' }
# tc_finder.rb:    u3 = User.find_or_create_by_name_and_age('tommy', 9) {|x| x.father = 'jack' }
# tc_finder.rb:    assert_equal(1, User.find_all_by_name('tommy').size)
# tc_has_many.rb:      :find_tags,
# tc_joins_many.rb:    t = Tag.find_by_name("Tag_1")
# tc_joins_many.rb:    i1.add_tag(Tag.find_by_name("Tag_1"))
# tc_joins_many.rb:    i1.add_tag(Tag.find_by_name("Tag_2"))
# tc_joins_many.rb:    i2.add_tag(Tag.find_by_name("Tag_2"))
# tc_joins_many.rb:    i2.add_tag(Tag.find_by_name("Tag_3"))
# tc_joins_many.rb:      i3.add_tag(Tag.find_by_name("Tag_1"))
# tc_joins_many.rb:      i3.add_tag(Tag.find_by_name("Tag_2"))
# tc_multiple.rb:    gmosx = User.find_by_name('gmosx')
# tc_resolve.rb:    users = User.find [ "name LIKE ? AND age > ?", 'G%', 4 ]
# tc_resolve.rb:    users = User.find [ "name LIKE ? AND age > ?", 'G%', 14 ]
# tc_resolve.rb:    User.find "name LIKE 'G%' LIMIT 1"
# tc_reverse.rb:    gmosx = User.find_by_name('gmosx')
# tc_reverse.rb:    helen = User.find_all_by_age(25).first
# tc_scoped.rb:    assert_equal 1, u.articles.find(:condition => 'hits > 15').size
# tc_scoped.rb:    assert_equal 20, u.articles.find(:condition => 'hits > 15').first.hits
# tc_store.rb:    acs = Article.find(:sql => "SELECT * FROM #{Article.table} WHERE oid=1")
# tc_store.rb:    acs = Article.find(:sql => "WHERE oid=1")
# tc_store.rb:    u = User.find_by_name('gmosx')
# tc_store.rb:    a = Article.find_by_body('Hello')
# tc_store.rb:    c = Category.find_by_title('News')
# tc_validation.rb:    framework = Framework.find_all_by_app_name(@app_name)

# tc_joins_many.rb:    sql = 'SELECT count(*) FROM ogj_tc_joinsmany_item_tc_joinsmany_tag'
# tc_multiple.rb:    assert_equal 2, Article.count
# tc_reldelete.rb:    assert_equal 1, Item.count, 'There should be 1 Item'
# tc_reldelete.rb:    assert_equal 1, Category.count
# tc_reldelete.rb:    assert_equal 1, Tag.count
# tc_reldelete.rb:    assert_equal 2, Picture.count
# tc_reldelete.rb:    assert_equal 2, Figure.count
# tc_reldelete.rb:    assert_equal 0, Category.count, "Category should be deleted"
# tc_reldelete.rb:    assert_equal 1, Tag.count, 'Tag shouldn\'t be deleted'
# tc_reldelete.rb:    assert_equal 0, Picture.count, "Pictures should be deleted"
# tc_reldelete.rb:    assert_equal 2, Figure.count, 'Figures shouldn\'t be deleted'
# tc_store.rb:    # count
# tc_store.rb:    assert_equal 4, @og.count(:class => Comment)
# tc_store.rb:    assert_equal 1, @og.count(:class => Comment, :condition => "body = 'Comment 4'")
# tc_store.rb:    assert_equal 4, Comment.count
# tc_store.rb:    assert_equal 1, Comment.count(:condition => "body = 'Comment 2'")
# tc_store.rb:    assert_equal 3, @og.count(:class => Comment)

