

class MRUCache

  def initialize(ideal_size, collection_threshold=nil)
    collection_threshold = (ideal_size * 1.5).round unless collection_threshold
    raise "ideal size must be >= 1" if ideal_size < 1
    raise "collection threshold can't be less than ideal size" if collection_threshold < ideal_size
    @ideal = ideal_size
    @thresh = collection_threshold
    @cache = {}
    @mru_idx = 0
  end

  def [](key)
    if (mru_node = @cache[key])
      mru_node[1] = (@mru_idx += 1)
      mru_node.first
    end
  end

  def []=(key,val)
    @cache[key] = [val, @mru_idx += 1]
    compact if @cache.size > @thresh
    val
  end

  def size
    @cache.size
  end
  alias length size

  def delete(key)
    @cache.delete key
  end

  def clear
    @cache.clear
    @mru_idx = 0
  end

  def has_key?(key)
    @cache.has_key? key
  end

  def keys
    @cache.keys
  end

  def values
    @cache.values.map {|mru_node| mru_node.first}
  end

  def each
    @cache.each_pair do |key, mru_node|
      yield [key, mru_node.first]
    end
  end

  def each_pair
    @cache.each_pair do |key, mru_node|
      yield(key, mru_node.first)
    end
  end

  def each_value
    @cache.each_value do |mru_node|
      yield mru_node.first
    end
  end

  def to_a
    @cache.to_a.map {|kv| kv[1] = kv[1].first; kv}
  end
  
  def compact
    lru_keys = @cache.keys.sort_by {|k| @cache[k].last}
    lru_keys.each do |key|
      break if @cache.size <= @ideal
      @cache.delete key
    end
  end

end



if $0 == __FILE__

  require 'test/unit'

  class TestMRUCache < Test::Unit::TestCase

    def test_mru_cache
      mc = MRUCache.new(3, 5)
      mc["foo"] = "aaa"
      mc["bar"] = "bbb"
      mc["baz"] = "ccc"
      mc["qux"] = "ddd"
      assert_equal( 4, mc.size )
      mc["xog"] = "eee"
      assert_equal( 5, mc.size )
      # foo is oldest, we'll access it:
      assert_equal( "aaa", mc["foo"] )
      
      assert_equal( %w(bar baz foo qux xog), mc.keys.sort )
      # adding another key should trip the threshold and 
      # knock bar, baz, and qux out:
      mc["yag"] = "fff"
      assert_equal( 3, mc.size )
      assert_equal( %w(foo xog yag), mc.keys.sort )
      
      a=[]; mc.each {|x| a<<x}
      assert_equal( [["foo","aaa"], ["xog","eee"], ["yag","fff"]], a.sort )

      a=[]; mc.each_pair {|k,v| a << [k,v]}
      assert_equal( [["foo","aaa"], ["xog","eee"], ["yag","fff"]], a.sort )

      a=[]; mc.each_value {|v| a << v}
      assert_equal( %w(aaa eee fff), a.sort )

      assert_equal( [["foo","aaa"], ["xog","eee"], ["yag","fff"]], mc.to_a.sort )
      
      mc.delete "xog"
      assert_equal( [["foo","aaa"], ["yag","fff"]], mc.to_a.sort )
      
      mc.clear
      assert_equal( 0, mc.size )
      assert_equal( [], mc.to_a.sort )
    end

  end

end


