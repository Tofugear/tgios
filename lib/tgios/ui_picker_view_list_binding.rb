module Tgios
  class UIPickerViewListBinding < BindingBase
    def initialize
      @events={}
    end

    def on(event_name, &block)
      @events[event_name]=block.weak!
    end

    def bind(picker_view, options={})
      @options = options
      @picker_view=WeakRef.new(picker_view)
      @list=WeakRef.new(options[:list])
      @display_field=options[:display_field]
      @picker_view.dataSource=self
      @picker_view.delegate=self
    end


    def numberOfComponentsInPickerView(pickerView)
      1
    end

    def pickerView(picker_view, numberOfRowsInComponent:section)
      @list.length
    end

    def pickerView(pickerView, titleForRow: row, forComponent: component)
      get_display_text(row)
    end

    def pickerView(pickerView, attributedTitleForRow:row, forComponent:component)
      if @options[:text_color]
        NSAttributedString.alloc.initWithString(get_display_text(row), attributes:{NSForegroundColorAttributeName => @options[:text_color]})
      end
    end

    def pickerView(pickerView, didSelectRow:row, inComponent:component)
      @events[:row_selected].call(row, selected_record) unless @events[:row_selected].nil?
    end

    def get_display_text(row)
      record = @list[row]
      record.is_a?(Hash) ? record[@display_field] : record.send(@display_field)
    end

    def selected_record
      @list[@picker_view.selectedRowInComponent(0)]
    end

    def select_record(record)
      idx = (@list.find_index(record) || 0)
      @picker_view.selectRow(idx, inComponent:0, animated: false)
    end

    def reload(list=nil)
      @list = WeakRef.new(list) if list
      NSLog "#{@list.length}====="
      @picker_view.reloadAllComponents
    end

    def onPrepareForRelease
      @events=nil
      @picker_view.dataSource=nil
      @picker_view.delegate=nil
      @list=nil
    end

  end
end