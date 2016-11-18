module Tgios
  class PhotoController < ExtendedUIViewController
    attr_accessor :url

    def viewDidLoad
      super
      self.view.backgroundColor = :black.uicolor

      @load_view = LoadingView.add_loading_view_to(self.view)
      unless @url.nil?
        @load_view.start_loading
        ImageLoader.load_url(@url) do |image, success|
          @load_view.stop_loading
          if success && self.view
            # TODO: use motion layout or other way to handle frame size (or allow full screen)
            small_frame = self.view.bounds
            small_frame.size.height -= 20 + 44 if small_frame == UIScreen.mainScreen.bounds

            scroll_view = PhotoScrollView.alloc.initWithFrame(small_frame, image: image)
            self.view.addSubview(scroll_view)
          end
        end

      end
    end

    def onPrepareForRelease
    end
  end
end