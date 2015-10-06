module Tgios
  class TableSectionListBinding < BindingBase
    Events = [:cell_identifier, :build_cell, :update_cell, :update_accessory,
        :get_section, :get_section_text, :get_section_footer_text, :get_rows, :get_row, :get_row_text, :get_row_detail_text,
        :touch_row, :delete_row, :can_delete_row,
        :cell_height, :section_header, :section_footer, :reach_bottom, :header_height, :footer_height
    ]

    def initialize(table_view, list, options={})
      @table = WeakRef.new(table_view)
      @table.dataSource = self
      @table.delegate = self
      @list = list

      @options = (options || {})

      @section_text_indicator = (@options.delete(:section_text_indicator) || :title)
      @section_footer_text_indicator = (@options.delete(:section_footer_text_indicator) || :footer_title)
      @rows_indicator = (@options.delete(:rows_indicator) || :rows)
      @row_text_indicator = (@options.delete(:row_text_indicator) || :title)
      @row_detail_indicator = (@options.delete(:row_detail_indicator) || :detail)


      @lines = (@options.delete(:lines) || 1)
      @lines = @lines == true ? 2 : @lines == false ? 1 : @lines
      @show_row_text = (@options.delete(:show_row_text) || true)
      @show_row_detail = (@options.delete(:show_row_detail) || false)


      @events = {}
      @events[:cell_identifier]=->(index_path, record) { 'CELL_IDENTIFIER' }.weak!
      @events[:build_cell]=->(cell_identifier, index_path, record) { build_cell(cell_identifier) }.weak!
      @events[:update_cell]=->(cell, index_path, record) { update_cell(cell, index_path, record)}.weak!
      @events[:update_accessory]=->(cell, index_path, record) { update_accessory(cell, index_path, record)}.weak!

      @events[:get_section]=->(index_path) { get_section(index_path) }.weak!
      @events[:get_section_text]=->(index_path, record) { get_section_text(index_path, record) }.weak!
      @events[:get_section_footer_text]=->(index_path, record) { get_section_footer_text(index_path, record) }.weak!
      @events[:get_rows]=->(index_path) { get_rows(index_path) }.weak!
      @events[:get_row]=->(index_path) { get_row(index_path) }.weak!
      @events[:get_row_text]=->(index_path, record) { get_row_text(index_path, record) }.weak!
      @events[:get_row_detail_text]=->(index_path, record) { get_row_detail_text(index_path, record) }.weak!

    end

    def onPrepareForRelease
      @events = {}
    end

    def on(event_key,&block)
      raise ArgumentError.new("Event not found, valid events are: [#{Events.join(', ')}]") unless Events.include?(event_key)
      @events[event_key] = block.weak!
      self
    end

    def reload(list=nil)
      @list = list unless list.nil?
      @table.reloadData
    end

    def get_section(index_path)
      section_idx = index_path.respondsToSelector(:section) ? index_path.section : index_path
      @list[section_idx]
    end

    def get_section_text(index_path, record=nil)
      record ||= @events[:get_section].call(index_path)
      text = record.is_a?(Hash) ? record[@section_text_indicator] : record.send(@section_text_indicator)
      text.to_s
    end

    def get_section_footer_text(index_path, record=nil)
      record ||= @events[:get_section].call(index_path)
      text = record.is_a?(Hash) ? record[@section_footer_text_indicator] : record.respond_to?(@section_footer_text_indicator) ? record.send(@section_footer_text_indicator) : nil
      text.nil? ? nil : text.to_s
    end

    def get_rows(index_path)
      record = @events[:get_section].call(index_path)
      rows = record.is_a?(Hash) ? record[@rows_indicator] : record.send(@rows_indicator)
      rows
    end

    def get_row(index_path)
      rows = @events[:get_rows].call(index_path)
      row_idx = index_path.respondsToSelector(:row) ? index_path.row : index_path
      rows[row_idx]
    end

    def get_row_text(index_path, record=nil)
      record ||= @events[:get_row].call(index_path)
      text = record.is_a?(Hash) ? record[@row_text_indicator] : record.send(@row_text_indicator)
      text.to_s
    end

    def get_row_detail_text(index_path, record=nil)
      record ||= @events[:get_row].call(index_path)
      text = record.is_a?(Hash) ? record[@row_detail_indicator] : record.send(@row_detail_indicator)
      text.to_s
    end

    def build_cell(cell_identifier)
      cell = UITableViewCell.value1(cell_identifier)
      cell.textLabel.adjustsFontSizeToFitWidth = true
      if @lines != 1
        cell.textLabel.numberOfLines = 0
      end
      cell.clipsToBounds = true
      cell
    end

    def update_cell(cell, index_path, record=nil)
      record ||= @events[:get_row].call(index_path)
      cell.textLabel.text = @events[:get_row_text].call(index_path, record) if @show_row_text
      cell.detailTextLabel.text = @events[:get_row_detail_text].call(index_path, record) if @show_row_detail
      cell.detailTextLabel
    end

    def update_accessory(cell, index_path, record)
      cell.accessoryType = (@options[:accessory] || :none).uitablecellaccessory
      cell.accessoryView = nil
    end

    def tableView(tableView, cellForRowAtIndexPath: index_path)
      record = @events[:get_row].call(index_path)
      cell_identifier = @events[:cell_identifier].call(index_path, record)
      cell=tableView.dequeueReusableCellWithIdentifier(cell_identifier)
      cell = @events[:build_cell].call(cell_identifier, index_path, record) if cell.nil?
      @events[:update_cell].call(cell, index_path, record)
      @events[:update_accessory].call(cell, index_path, record)
      cell
    end

    def tableView(tableView, didSelectRowAtIndexPath:index_path)
      if @events.has_key?(:touch_row)
        record = @events[:get_row].call(index_path)
        @events[:touch_row].call(record, index_path)
      end
    end

    def tableView(tableView, commitEditingStyle: editingStyle, forRowAtIndexPath: index_path)
      if editingStyle == UITableViewCellEditingStyleDelete
        if @events[:delete_row].present?
          record = @events[:get_row].call(index_path)
          @events[:delete_row].call(index_path, record) do |success|
            tableView.deleteRowsAtIndexPaths([index_path], withRowAnimation: UITableViewRowAnimationFade) if success
          end
        end
      end
    end

    def tableView(tableView, canEditRowAtIndexPath:index_path)
      if @events[:can_delete_row].present?
        record = @events[:get_row].call(index_path)
        @events[:can_delete_row].call(index_path, record)
      else
        @events[:delete_row].present?
      end
    end

    def tableView(tableView, numberOfRowsInSection: section)
      rows = @events[:get_rows].call(section)
      rows.length
    end

    def numberOfSectionsInTableView(tableView)
      @list.length
    end

    def tableView(tableView, heightForRowAtIndexPath: index_path)
      height = if @events.has_key?(:cell_height)
                 record = @events[:get_row].call(index_path)
                 @events[:cell_height].call(index_path, record)
               end
      return height if height.is_a?(Numeric)
      return @options[:height] unless @options[:height].nil?
      26 + 19 * @lines
    end

    def tableView(tableView, titleForHeaderInSection:section)
      record = @events[:get_section].call(section)
      @events[:get_section_text].call(section, record)
    end

    def tableView(tableView, viewForHeaderInSection:section)
      record = @events[:get_section].call(section)
      @events[:section_header].call(section, record) if @events.has_key?(:section_header)
    end

    def tableView(tableView, heightForHeaderInSection:section)
      height = if @events.has_key?(:header_height)
                 record = @events[:get_section].call(section)
                 @events[:header_height].call(section, record)
               end
      return height if height.is_a?(Numeric)
      return @options[:header_height] unless @options[:header_height].nil?
      24
    end

    def tableView(tableView, titleForFooterInSection:section)
      record = @events[:get_section].call(section)
      @events[:get_section_footer_text].call(section, record)
    end

    def tableView(tableView, viewForFooterInSection:section)
      record = @events[:get_section].call(section)
      @events[:section_footer].call(section, record) if @events.has_key?(:section_footer)
    end

    def tableView(tableView, heightForFooterInSection:section)
      height = if @events.has_key?(:footer_height)
                 record = @events[:get_section].call(section)
                 @events[:footer_height].call(section, record)
               end
      return height if height.is_a?(Numeric)
      return @options[:footer_height] unless @options[:footer_height].nil?
      0
    end


    def tableView(tableView, willDisplayCell:cell, forRowAtIndexPath:index_path)
      unless @events[:reach_bottom].nil? || index_path.section < @list.length - 1 || index_path.row < @events[:get_rows].call(index_path).length - 1
        record = @events[:get_row].call(index_path)
        @events[:reach_bottom].call(index_path, record)
      end
    end

  end
end