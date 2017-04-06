require File.join(File.dirname(__FILE__), '_lib.rb')

class MoSQL::Test::Functional::SchemaTest < MoSQL::Test::Functional
  TEST_MAP = <<EOF
---
db:
  collection:
    :meta:
      :table: sqltable
    :columns:
      - _id: TEXT
      - var: INTEGER
      - arry: INTEGER ARRAY
  with_extra_props:
    :meta:
      :table: sqltable2
      :extra_props: true
    :columns:
      - _id: TEXT
  with_dotted:
    :meta:
      :table: sqltable3
      :extra_props: true
    :columns:
      - _id: TEXT
      - var_a:
        :source: vars.a
        :type: TEXT
      - var_b:
        :source: vars.b
        :type: TEXT
EOF

  before do
    @map = MoSQL::Schema.new(YAML.load(TEST_MAP))

    @sequel.drop_table?(:sqltable)
    @sequel.drop_table?(:sqltable2)
    @sequel.drop_table?(:sqltable3)
    @map.create_schema(@sequel)
  end

  def table; @sequel[:sqltable]; end
  def table2; @sequel[:sqltable2]; end
  def table3; @sequel[:sqltable3]; end

  it 'Creates the tables with the right columns' do
    assert_equal(Set.new([:_id, :var, :arry]),
                 Set.new(table.columns))
    assert_equal(Set.new([:_id, :_extra_props]),
                 Set.new(table2.columns))
  end

  it 'Can COPY data' do
    objects = [
               {'_id' => "a", 'var' => 0},
               {'_id' => "b", 'var' => 1, 'arry' => "{1, 2, 3}"},
               {'_id' => "c"},
               {'_id' => "d", 'other_var' => "hello"}
              ]
    @map.copy_data(@sequel, 'db.collection', objects.map { |o| @map.transform('db.collection', o) } )
    assert_equal(4, table.count)
    rows = table.select.sort_by { |r| r[:_id] }
    assert_equal(%w[a b c d], rows.map { |r| r[:_id] })
    assert_equal(nil, rows[2][:var])
    assert_equal(nil, rows[3][:var])
    assert_equal([1 ,2, 3], rows[1][:arry])
  end

  it 'Can COPY dotted data' do
    objects = [
               {'_id' => "a", 'vars' => {'a' => 1, 'b' => 2}},
               {'_id' => "b", 'vars' => {}},
               {'_id' => "c", 'vars' => {'a' => 2, 'c' => 6}},
               {'_id' => "d", 'vars' => {'a' => 1, 'c' => 7}, 'extra' => 'moo'}
              ]
    @map.copy_data(@sequel, 'db.with_dotted', objects.map { |o| @map.transform('db.with_dotted', o) } )
    assert_equal(4, table3.count)
    o = table3.first(:_id => 'a')
    assert_equal("1", o[:var_a])
    assert_equal("2", o[:var_b])

    o = table3.first(:_id => 'b')
    assert_equal({}, JSON.parse(o[:_extra_props]))

    o = table3.first(:_id => 'c')
    assert_equal({'vars' => { 'c' => 6} }, JSON.parse(o[:_extra_props]))

    o = table3.first(:_id => 'd')
    assert_equal({'vars' => { 'c' => 7}, 'extra' => 'moo' }, JSON.parse(o[:_extra_props]))
    assert_equal(nil, o[:var_b])
  end

  it 'Can COPY BSON::ObjectIDs' do
    o = {'_id' => BSON::ObjectId.new, 'var' => 0}
    @map.copy_data(@sequel, 'db.collection', [ @map.transform('db.collection', o)] )
    assert_equal(o['_id'].to_s, table.select.first[:_id])
  end

  it 'Can transform BSON::ObjectIDs' do
    o = {'_id' => BSON::ObjectId.new, 'var' => 0}
    row = @map.transform('db.collection', o)
    table.insert(row)
    assert_equal(o['_id'].to_s, table.select.first[:_id])
  end

  describe "post_process" do
    POST_PROCESS_MAP = <<-EOF
db:
  post_process:
    :meta:
      :table: post_process
    :columns:
      - _id: TEXT
      - optional_data:
        :source: optional_data
        :post_process: lambda { |x| x || "default" }
        :type: TEXT
      - dual_type_col:
        :source: dual_type_col
        :post_process: lambda { |x| x.to_i }
        :type: integer
      - reused_a:
        :source: reused
        :reused: true
        :type: TEXT
      - reused_b:
        :source: reused
        :reused: true
        :type: TEXT
      - :name: explicit_name
        :source: not_exist
        :reused: true
        :type: TEXT
        :post_process: lambda { |x| "explicit" }
    EOF
    before do
      @post_process_map = MoSQL::Schema.new(YAML.load(POST_PROCESS_MAP))

      @sequel.drop_table?(:post_process)
      @post_process_map.create_schema(@sequel)
    end
    it "can set a default for an optional data" do
      objects = [
        { _id: "a", optional_data: "test"},
        { _id: "b"},
      ]
      @post_process_map.copy_data(@sequel, "db.post_process", objects.map { |o| @post_process_map.transform("db.post_process", o)})
      b = @sequel[:post_process].select.first(_id: "b")
      assert_equal(b[:optional_data], "default")
    end

    it "can use an explict name" do
      objects = [
        { _id: "a", optional_data: "test"},
        { _id: "b"},
      ]
      @post_process_map.copy_data(@sequel, "db.post_process", objects.map { |o| @post_process_map.transform("db.post_process", o)})
      b = @sequel[:post_process].select.first(_id: "b")
      assert_equal(b[:explicit_name], "explicit")
    end

    it "can reuse source column if needed" do
      objects = [
        { _id: "a", reused: "test"},
      ]
      @post_process_map.copy_data(@sequel, "db.post_process", objects.map { |o| @post_process_map.transform("db.post_process", o)})
      a = @sequel[:post_process].select.first(_id: "a")
      assert_equal(a[:reused_a], "test")
      assert_equal(a[:reused_b], "test")
    end

    it "can convert type" do
      objects = [
        { _id: "a", dual_type_col: "5566"},
        { _id: "b", dual_type_col: 5566},
      ]
      transformed = objects.map { |o| @post_process_map.transform("db.post_process", o)}
      @post_process_map.copy_data(@sequel, "db.post_process", transformed)
      a = @sequel[:post_process].select.first(_id: "a")
      assert_equal(a[:dual_type_col], 5566)
      b = @sequel[:post_process].select.first(_id: "b")
      assert_equal(b[:dual_type_col], 5566)
    end

  end

  describe "related fields" do
    RELATED_MAP = <<-EOF
db:
  parents:
    :meta:
      :table: related_main
    :columns:
      - _id: TEXT
      - uuid:
        :source: uuid
        :type: uuid
    :related:
      :children:
        - _id:
          :source: children[]._id
          :type: TEXT
          :primary_key: true
        - parent_id:
          :source: uuid
          :type: uuid
    EOF
    before do
      @related_map = MoSQL::Schema.new(YAML.load(RELATED_MAP))

      @sequel.drop_table?(:related_main)
      @sequel.drop_table?(:children)
      @related_map.create_schema(@sequel)
    end

    let(:parent_table) { @sequel[:related_main] }
    let(:children_table) { @sequel[:children] }

    it "can create db by schema" do
      assert_equal([:_id,:uuid],@sequel[:related_main].columns)
      assert_equal([:_id, :parent_id], @sequel[:children].columns)
    end

    it "can get all_related_ns" do
      assert_equal(@related_map.all_related_ns("db.parents"), ["db.parents.related.children"])
    end

    it "can get primary_key for children ns" do
      assert_equal(@related_map.primary_sql_key_for_ns("db.parents.related.children"), ["_id"])
    end

    it "can copy data" do
      objects = [
        { _id: "a", uuid: SecureRandom.uuid, children: [{_id: "a_a"}, {_id: "a_b"}]},
        { _id: "b", uuid: SecureRandom.uuid, children: [{_id: "b_a"}, {_id: "b_b"}]}
      ]
      @related_map.copy_data(@sequel, "db.parents", objects.map { |o| @related_map.transform("db.parents", o) } )
      mapped = objects.flat_map { |o| @related_map.transform_related("db.parents.related.children", o) }
      @related_map.copy_data(@sequel, "db.parents.related.children", mapped)
      first_parent_obj = objects[0].select{|k,v| [:_id, :uuid].include?(k)}
      assert_equal(first_parent_obj, parent_table.first(_id: "a"))
      first_child_obj = objects[0][:children][0]
      first_child_obj[:parent_id] = first_parent_obj[:uuid]
      assert_equal(first_child_obj, children_table.first(_id: "a_a"))

    end
  end

  describe "nested related fields" do
    NESTED_RELATED_MAP = <<-EOF
db:
  parents:
    :meta:
      :table: related_main
    :columns:
      - _id: TEXT
      - uuid:
        :source: uuid
        :type: uuid
    :related:
      :children:
        - _id:
          :source: children[]._id
          :type: TEXT
        - nested:
          :source: children[].nested[].id
          :type: TEXT
          :primary_key: true
        - nested_info:
          :source: children[].nested[].info
          :type: TEXT
        - parent_id:
          :source: uuid
          :type: uuid
          :reused: true
        - parent_uuid:
          :source: uuid
          :type: uuid
          :reused: true
    EOF
    before do
      @related_map = MoSQL::Schema.new(YAML.load(NESTED_RELATED_MAP))

      @sequel.drop_table?(:related_main)
      @sequel.drop_table?(:children)
      @related_map.create_schema(@sequel, true)
    end

    let(:parent_table) { @sequel[:related_main] }
    let(:children_table) { @sequel[:children] }

    it "can create db by schema" do
      assert_equal([:_id, :uuid],@sequel[:related_main].columns)
      assert_equal([:_id, :nested, :nested_info, :parent_id, :parent_uuid], @sequel[:children].columns)
    end

    it "can get all_related_ns" do
      assert_equal(@related_map.all_related_ns("db.parents"), ["db.parents.related.children"])
    end

    it "can get primary_key for children ns" do
      assert_equal(@related_map.primary_sql_key_for_ns("db.parents.related.children"), ["nested"])
    end

    it "can copy data" do
      objects = [
        { _id: "a", uuid: SecureRandom.uuid, children: [{_id: "a_a", nested:[{id: "a_a_1", info: "aa1i"}, {id:"a_a_2", info: "aa2i"}]}, {_id: "a_b", nested:[{id: "a_b_1", info: "ab1i"}, {id:"a_b_2", info: "ab2i"}]}]},
        { _id: "b", uuid: SecureRandom.uuid, children: [{_id: "b_a", nested:[{id: "b_a_1", info: "ba1i"}, {id:"b_a_2", info: "ba2i"}]}, {_id: "b_b", nested:[{id: "b_b_1", info: "bb1i"}, {id:"b_b_2", info: "bb2i"}]}]}
      ]
      @related_map.copy_data(@sequel, "db.parents", objects.map { |o| @related_map.transform("db.parents", o) } )
      mapped = objects.flat_map { |o| @related_map.transform_related("db.parents.related.children", o) }
      @related_map.copy_data(@sequel, "db.parents.related.children", mapped)
      first_parent_obj = objects[0].select{|k,v| [:_id, :uuid].include?(k)}
      assert_equal(first_parent_obj, parent_table.first(_id: "a"))
      first_child_obj = objects[0][:children][0]
      first_child_obj[:parent_id] = first_parent_obj[:uuid]
      assert_equal(8, children_table.count)
      aa1 = children_table.where(nested: "a_a_1").all[0]
      assert_equal(aa1[:_id], "a_a")
      aa2 = children_table.where(nested: "a_a_2").all[0]
      assert_equal(aa2[:_id], "a_a")
    end

    it "can transform related data with first nested nil" do
      objects = [
        { _id: "a", uuid: SecureRandom.uuid, children: [{_id: "a_a", nested:[]}, {_id: "a_b", nested:[{id: "a_b_1", info: "ab1i"}, {id:"a_b_2", info: "ab2i"}]}]},
      ]
      mapped = objects.flat_map { |o| @related_map.transform_related("db.parents.related.children", o) }
      assert_equal(mapped.count, 3)
    end


  end

  describe "three layer nested related fields" do
    THREE_LAYER_NESTED_RELATED_MAP = <<-EOF
db:
  parents:
    :meta:
      :table: related_main
    :columns:
      - _id: TEXT
      - uuid:
        :source: uuid
        :type: uuid
    :related:
      :children:
        - _id:
          :source: children[]._id
          :type: TEXT
        - third_layer:
          :source: children[].nested[].third[].id
          :type: TEXT
          :nonnull: true
        - nested:
          :source: children[].nested[].id
          :type: TEXT
          :primary_key: true
        - nested_info:
          :source: children[].nested[].info
          :type: TEXT
        - parent_id:
          :source: uuid
          :type: uuid
          :reused: true
        - parent_uuid:
          :source: uuid
          :type: uuid
          :reused: true
    EOF
    before do
      @related_map = MoSQL::Schema.new(YAML.load(THREE_LAYER_NESTED_RELATED_MAP))

      @sequel.drop_table?(:related_main)
      @sequel.drop_table?(:children)
      @related_map.create_schema(@sequel, true)
    end

    it "can transform related data with first third layer nil" do
      objects = [
        { _id: "a", uuid: SecureRandom.uuid, children: [{_id: "a_b", nested:[{id: "a_b_1", info: "ab1i", third:[]}, {id:"a_b_2", info: "ab2i", third:[id: "thrid"]}]}]},
      ]
      mapped = objects.flat_map { |o| @related_map.transform_related("db.parents.related.children", o) }
      assert_equal(mapped.count, 2)
      assert_raises Sequel::NotNullConstraintViolation do
        @related_map.copy_data(@sequel, "db.parents.related.children", mapped)
      end
    end

  end

  describe 'special fields' do
  SPECIAL_MAP = <<EOF
---
db:
  collection:
    :meta:
      :table: special
    :columns:
      - _id: TEXT
      - id:
        :type: Serial
        :source: $default
      - mosql_updated:
        :source: $timestamp
        :type: timestamp
EOF

    before do
      @specialmap = MoSQL::Schema.new(YAML.load(SPECIAL_MAP))

      @sequel.drop_table?(:special)
      @specialmap.create_schema(@sequel)
    end

    it 'sets a default on the column' do
      @sequel[:special].insert({_id: 'a'})
      row = @sequel[:special].select.first
      assert_instance_of(Time, row[:mosql_updated])
    end

    it 'Can set default on Serial when COPY' do
      objects = [
                 {'_id' => "a"},
                 {'_id' => "b"}
                ]
      Sequel.database_timezone = Time.now.zone
      @specialmap.copy_data(@sequel, 'db.collection',
                            objects.map { |o| @specialmap.transform('db.collection', o) } )
      rows = @sequel[:special].select.sort_by { |r| r[:_id] }
      assert_operator(rows[0][:id], :<, rows[1][:id])
    end

    it 'Can populate $timestamp on COPY' do
      objects = [
                 {'_id' => "a"},
                 {'_id' => "b"}
                ]
      Sequel.database_timezone = Time.now.zone
      before = @sequel.select(Sequel.function(:NOW)).first[:now]
      @specialmap.copy_data(@sequel, 'db.collection',
                            objects.map { |o| @specialmap.transform('db.collection', o) } )
      after = @sequel.select(Sequel.function(:NOW)).first[:now]
      rows = @sequel[:special].select.sort_by { |r| r[:_id] }

      assert_instance_of(Time, rows[0][:mosql_updated])
      assert_operator(rows[0][:mosql_updated], :>, before)
      assert_operator(rows[0][:mosql_updated], :<, after)
    end
  end
end
