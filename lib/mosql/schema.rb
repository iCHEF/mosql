module MoSQL
  class SchemaError < StandardError; end;

  class Schema
    include MoSQL::Logging

    def compile_post_process(str)
      return nil unless str && str.length > 0
      eval(str)
    end

    def to_array(lst)
      lst.map do |ent|
        col = nil
        if ent.is_a?(Hash) && ent[:source].is_a?(String) && ent[:type].is_a?(String)
          # new configuration format
          col = {
            :source => ent.fetch(:source),
            :type   => ent.fetch(:type),
            :name   => ent.fetch(:name, (ent.keys - [:source, :type]).first),
            :post_process => compile_post_process(ent.fetch(:post_process, nil)),
            :primary_key => ent.fetch(:primary_key, false),
            :reused => ent.fetch(:reused, false),
          }
        elsif ent.is_a?(Hash) && ent.keys.length == 1 && ent.values.first.is_a?(String)
          col = {
            :source => ent.first.first,
            :name   => ent.first.first,
            :type   => ent.first.last,
            :primary_key => ent.fetch(:primary_key, false),
            :post_process => nil,
            :reused => false,
          }
        else
          raise SchemaError.new("Invalid ordered hash entry #{ent.inspect}")
        end

        if !col.key?(:array_type) && /\A(.+)\s+array\z/i.match(col[:type])
          col[:array_type] = $1
        end

        col
      end
    end

    def check_columns!(ns, columns)
      seen = Set.new
      columns.each do |col|
        next if col[:reused]
        if seen.include?(col[:source])
          raise SchemaError.new("Duplicate source #{col[:source]} in column definition #{col[:name]} for #{ns}.")
        end
        seen.add(col[:source])
      end
    end

    def parse_related_spec(spec)
      spec.fetch(:related, {}).map do |k,v|
        [k, to_array(v)]
      end.to_h
    end

    def parse_spec(ns, spec)
      out = spec.dup
      out[:columns] = to_array(spec.fetch(:columns))
      out[:related] = parse_related_spec(spec)
      check_columns!(ns, out[:columns])
      out[:related].values.each do |columns|
        check_columns!(ns, columns)
      end
      out
    end

    def parse_meta(meta)
      meta = {} if meta.nil?
      meta[:alias] = [] unless meta.key?(:alias)
      meta[:alias] = [meta[:alias]] unless meta[:alias].is_a?(Array)
      meta[:alias] = meta[:alias].map { |r| Regexp.new(r) }
      meta
    end

    def initialize(map)
      @map = {}
      map.each do |dbname, db|
        @map[dbname] = { :meta => parse_meta(db[:meta]) }
        db.each do |cname, spec|
          next unless cname.is_a?(String)
          begin
            @map[dbname][cname] = parse_spec("#{dbname}.#{cname}", spec)
          rescue KeyError => e
            raise SchemaError.new("In spec for #{dbname}.#{cname}: #{e}")
          end
        end
      end

      # Lurky way to force Sequel force all timestamps to use UTC.
      Sequel.default_timezone = :utc
    end

    def create_schema_for_related_tables(db, related, clobber)
      return unless related
      related.map do |name,columns|
        log.info("Creating related table '#{name}'...")
        db.send(clobber ? :create_table! : :create_table?, name) do
          columns.each do |col|
            column col[:name], col[:type]
          end

        end
      end
    end

    def create_schema_for_collection(db, collection, clobber)
      meta = collection[:meta]
      composite_key = meta[:composite_key]
      keys = []
      log.info("Creating table '#{meta[:table]}'...")
      db.send(clobber ? :create_table! : :create_table?, meta[:table]) do
        collection[:columns].each do |col|
          opts = {}
          if col[:source] == '$timestamp'
            opts[:default] = Sequel.function(:now)
          end
          column col[:name], col[:type], opts

              if composite_key and composite_key.include?(col[:name])
                keys << col[:name].to_sym
              elsif not composite_key and col[:source].to_sym == :_id
                keys << col[:name].to_sym
              end
            end

            primary_key keys
            if meta[:extra_props]
              type =
                case meta[:extra_props]
                when 'JSON'
                  'JSON'
                when 'JSONB'
                  'JSONB'
                else
                  'TEXT'
                end
              column '_extra_props', type
            end
      end
    end

    def create_schema(db, clobber=false)
      @map.values.each do |dbspec|
        dbspec.each do |n, collection|
          next unless n.is_a?(String)
          create_schema_for_collection(db, collection, clobber)
          create_schema_for_related_tables(db, collection[:related], clobber)

        end
      end
    end

    def find_db(db)
      unless @map.key?(db)
        @map[db] = @map.values.find do |spec|
          spec && spec[:meta][:alias].any? { |a| a.match(db) }
        end
      end
      @map[db]
    end

    def related_schema(schema, relation)
      return schema unless relation
      {
        columns: schema[:related][relation.to_sym],
        meta: { table: relation }
      }
    end

    def all_related_ns(ns)
      main_ns = find_ns(ns)
      related_keys = main_ns.fetch( :related, {} ).keys
      related_keys.map{|k| "#{ns}.related.#{k.to_s}"}
    end

    def find_ns(ns)
      if matched = ns.match(/([^.]+)\.(.+)\.related\.(.+)/)
        _, db, collection, relation = *matched.to_a
      else
        db, collection = ns.split(".", 2)
      end
      unless spec = find_db(db)
        return nil
      end
      unless schema = spec[collection]
        log.debug("No mapping for ns: #{ns}")
        return nil
      end
      related_schema(schema, relation)
    end

    def find_ns!(ns)
      schema = find_ns(ns)
      raise SchemaError.new("No mapping for namespace: #{ns}") if schema.nil?
      schema
    end

    class ChildrenArray < Array
    end

    def fetch_and_delete_ary_dotted(obj, key, rest, reused=false)
      real_key = key.delete("[]")
      return nil unless obj.has_key?(real_key)
      result = obj[real_key].map do |o|
        fetch_and_delete_dotted(o, rest, reused)
      end
      obj.delete(real_key) if obj[real_key].all?{|o| o.empty?}
      ChildrenArray.new(result)
    end

    def fetch_and_delete_dotted(obj, dotted, reused=false)
      key, rest = dotted.split(".", 2)
      obj ||= {}
      return fetch_and_delete_ary_dotted(obj, key, rest, reused) if key.end_with?("[]")
      return nil unless obj.has_key?(key)
      unless rest
        result = obj.fetch(key)
        obj.delete(key) unless reused
        return result
      end
      val = fetch_and_delete_dotted(obj[key], rest, reused)
      obj.delete(key) if obj[key].empty? and !reused
      return val
    end

    def fetch_exists(obj, dotted)
      pieces = dotted.split(".")
      while pieces.length > 1
        key = pieces.shift
        obj = obj[key]
        return false unless obj.is_a?(Hash)
      end
      obj.has_key?(pieces.first)
    end

    def fetch_special_source(obj, source, original)
      case source
      when "$timestamp"
        Sequel.function(:now)
      when /^\$exists (.+)/
        # We need to look in the cloned original object, not in the version that
        # has had some fields deleted.
        fetch_exists(original, $1)
      else
        raise SchemaError.new("Unknown source: #{source}")
      end
    end

    def transform_primitive(v, type=nil)
      case v
      when BSON::ObjectId, Symbol
        v.to_s
      when BSON::Binary
        if type.downcase == 'uuid'
          v.to_s.unpack("H*").first
        else
          Sequel::SQL::Blob.new(v.to_s)
        end
      when BSON::DBRef
        v.object_id.to_s
      else
        v
      end
    end

    def transform_related(ns, obj, schema=nil)
      row = transform(ns, obj, schema)
      unfold_rows(row)
    end

    def transform(ns, obj, schema=nil)
      schema ||= find_ns!(ns)

      original = obj

      # Do a deep clone, because we're potentially going to be
      # mutating embedded objects.
      obj = BSON.deserialize(BSON.serialize(obj))

      row = []
      schema[:columns].each do |col|

        source = col[:source]
        type = col[:type]
        reused = col[:reused]

        if source.start_with?("$")
          next if source == "$default"
          v = fetch_special_source(obj, source, original)
        else
          v = fetch_and_delete_dotted(obj, source, reused)
        end
        case v
        when Hash
          v = JSON.dump(Hash[v.map { |k,v| [k, transform_primitive(v)] }])
        when ChildrenArray
          #noop
        when Array
          v = v.map { |it| transform_primitive(it) }
          if col[:array_type]
            v = Sequel.pg_array(v, col[:array_type])
          else
            v = JSON.dump(v)
          end
        else
          v = transform_primitive(v, type)
        end
        post_process_block = col[:post_process]
        v = post_process_block.call(v) if post_process_block
        row << v
      end

      if schema[:meta][:extra_props]
        extra = sanitize(obj)
        row << JSON.dump(extra)
      end

      log.debug { "Transformed: #{row.inspect}" }

      row
    end

    def array_depth(ary)
      # It assums the array is homogenerous
      return 0 unless ary.is_a? Array
      return 1 + array_depth(ary[0])
    end

    require 'tree'
    Node=Tree::TreeNode
    def make_tree(node, ary)
      return unless ary && !ary.empty?
      idx = node.name.to_i
      sub_ary = ary.map{|elm| elm[idx]}
      children_vals = sub_ary[0]
      children = children_vals.map.with_index{|val, i| Node.new(i.to_s, val)}
      tail = sub_ary[1..-1]
      children.each do |child|
        node << child
        make_tree(child, tail)
      end
    end

    def row_nested?(row)
      row.any?{|col| col.is_a?(Array) && col.any?{|x| x.is_a?(Array)}}
    end

    def row_from_leaf(node)
      reversed_row_from_leaf(node).reverse
    end

    def reversed_row_from_leaf(node)
      return [node.content] if node.is_root?
      return [node.content] + reversed_row_from_leaf(node.parent)
    end

    def nested_unfold_rows(row)
      # Convert row [a, [b, c], [[d,e], [f,g]]] into [[a, b, d], [a, b, e], [a, c, f], [a, c, g]]
      arrayed_columns = row.map{|c| [c]}
      columns_with_orig_index = arrayed_columns.each_with_index.to_a
      cols_by_depth = columns_with_orig_index.sort_by{|c,i| array_depth(c)}
      orig_index = cols_by_depth.map{|c,i| i}
      cols = cols_by_depth.map{|c,i| c}
      root = Node.new("0", cols[0][0])
      make_tree(root, cols[1..-1])
      leaves = root.find_all(&:is_leaf?)
      rows = leaves.map{|leaf| row_from_leaf(leaf)}
      rows_with_orig_ordering = rows.map do |r|
        r.zip(orig_index).sort_by(&:last).map(&:first)
      end
      rows_with_orig_ordering
    end

    def unfold_rows(row)
      # Convert row [a, [b, c], d] into [[a, b, d], [a, c, d]]
      return nested_unfold_rows(row) if row_nested?(row)
      depth = row.select {|r| r.is_a? Array}.map {|r| [r].flatten.length }.max
      row.map! {|r| [r].flatten.cycle.take(depth)}
      row.first.zip(*row.drop(1))
    end

    def sanitize(value)
      # Base64-encode binary blobs from _extra_props -- they may
      # contain invalid UTF-8, which to_json will not properly encode.
      case value
      when Hash
        ret = {}
        value.each {|k, v| ret[k] = sanitize(v)}
        ret
      when Array
        value.map {|v| sanitize(v)}
      when BSON::Binary
        Base64.encode64(value.to_s)
      when Float
        # NaN is illegal in JSON. Translate into null.
        value.nan? ? nil : value
      else
        value
      end
    end

    def copy_column?(col)
      ['$timestamp', '$default'].include?(col[:source]).!
    end

    def is_default?(col)
      col[:source] == "$default"
    end

    def all_columns(schema, copy=false)
      cols = []
      schema[:columns].each do |col|
        next if is_default?(col)
        cols << col[:name] unless copy && !copy_column?(col)
      end
      if schema[:meta][:extra_props]
        cols << "_extra_props"
      end
      cols
    end

    def all_columns_for_copy(schema)
      all_columns(schema, true)
    end

    def copy_data(db, ns, objs)
      schema = find_ns!(ns)
      db.synchronize do |pg|
        sql = "COPY \"#{schema[:meta][:table]}\" " +
          "(#{all_columns_for_copy(schema).map {|c| "\"#{c}\""}.join(",")}) FROM STDIN"
        pg.execute(sql)
        objs.each do |o|
          pg.put_copy_data(transform_to_copy(ns, o, schema) + "\n")
        end
        pg.put_copy_end
        begin
          pg.get_result.check
        rescue PGError => e
          db.send(:raise_error, e)
        end
      end
    end

    def quote_copy(val)
      case val
      when nil
        "\\N"
      when true
        't'
      when false
        'f'
      when Sequel::SQL::Function
        nil
      when DateTime, Time
        val.strftime("%FT%T.%6N %z")
      when Sequel::SQL::Blob
        "\\\\x" + [val].pack("h*")
      else
        val.to_s.gsub(/([\\\t\n\r])/, '\\\\\\1')
      end
    end

    def transform_to_copy(ns, row, schema=nil)
      row.map { |c| quote_copy(c) }.compact.join("\t")
    end

    def table_for_ns(ns)
      find_ns!(ns)[:meta][:table]
    end

    def all_mongo_dbs
      @map.keys
    end

    def collections_for_mongo_db(db)
      (@map[db]||{}).keys
    end

    def primary_sql_key_for_ns(ns)
      ns = find_ns!(ns)
      keys = []
      if ns[:meta][:composite_key]
        keys = ns[:meta][:composite_key]
      else
        keys << ns[:columns].find {|c| c[:source] == '_id' || c.fetch(:primary_key)}[:name]
      end

      return keys
    end
  end
end
