module Tgios
  class ScanQrController < UIViewController
    attr_accessor :types, :bottom_text

    def viewDidLoad
      super
      self.view.backgroundColor = :dark_gray.uicolor
      @load_view = Tgios::LoadingView.add_loading_view_to(self.view)
      @load_view.start_loading
      if CommonUIUtility.simulator?
        self.performSelector('fake_scan', withObject: nil, afterDelay: 3)
      else
        check_permission
        # self.performSelector('startScanning', withObject: nil, afterDelay: 0.5)
      end

    end

    def check_permission
      status = AVCaptureDevice.authorizationStatusForMediaType(AVMediaTypeVideo)
      if status == AVAuthorizationStatusAuthorized
        self.performSelector('startScanning', withObject: nil, afterDelay: 0.5)
      elsif status == AVAuthorizationStatusNotDetermined
        Dispatch::Queue.new('ScanQrController').async do
          AVCaptureDevice.requestAccessForMediaType(AVMediaTypeVideo, completionHandler: ->(granted) {
                if granted
                  Dispatch::Queue.main.async do
                    startScanning
                  end
                else
                  Dispatch::Queue.main.async do
                    @events[:permission_denied].call if @events[:permission_denied]
                  end
                end
              })
        end
      else
        @events[:permission_denied].call if @events[:permission_denied]
      end
    end

    def startScanning
      @load_view.stop_loading
      setupCapture
    end

    def setupCapture
      #NSLog "setCapture()"

      @session = AVCaptureSession.alloc.init
      @session.sessionPreset = AVCaptureSessionPresetHigh

      @device = AVCaptureDevice.defaultDeviceWithMediaType AVMediaTypeVideo
      if @device.lockForConfiguration(nil)
        if @device.isFocusModeSupported(AVCaptureFocusModeContinuousAutoFocus)
          @device.focusMode = AVCaptureFocusModeContinuousAutoFocus
        end
        if @device.isAutoFocusRangeRestrictionSupported
          @device.autoFocusRangeRestriction = AVCaptureAutoFocusRangeRestrictionNear
        end
        @device.unlockForConfiguration
      end

      @error = Pointer.new('@')
      @input = AVCaptureDeviceInput.deviceInputWithDevice @device, error: @error

      if @bottom_text
        bottom_bg = Base.style(UIView.new, backgroundColor: :black.uicolor(0.3))
        Motion::Layout.new do |l|
          l.view self.view
          l.subviews bg: bottom_bg
          l.vertical '[bg]|'
          l.horizontal '|[bg]|'
        end
        bottom_label = Base.style(UILabel.new,
            font: :system.uifont(14),
            textColor: :white.uicolor,
            textAlignment: :center.nsalignment,
            numberOfLines: 0,
            text: @bottom_text)
        Motion::Layout.new do |l|
          l.view bottom_bg
          l.subviews lbl: bottom_label
          l.vertical '|-10-[lbl]-10-|'
          l.horizontal '|-10-[lbl]-10-|'
        end
      end

      @previewLayer = AVCaptureVideoPreviewLayer.alloc.initWithSession(@session)
      @previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill
      layerRect = self.view.layer.bounds
      @previewLayer.bounds = layerRect
      @previewLayer.setPosition(CGPointMake(CGRectGetMidX(layerRect), CGRectGetMidY(layerRect)))
      if bottom_bg
        self.view.layer.insertSublayer(@previewLayer, below: bottom_bg.layer)
      else
        self.view.layer.addSublayer(@previewLayer)
      end

      @queue = Dispatch::Queue.new('camQueue')
      @output = AVCaptureMetadataOutput.alloc.init
      @output.setMetadataObjectsDelegate self, queue: @queue.dispatch_object

      camera_size = layerRect.size
      sq_size = 240
      sq_border = 20
      line_length = 60
      border_color = :white.cgcolor(0.8)
      sq_x = (camera_size.width - sq_size) / 2
      sq_y = (camera_size.height - sq_size) / 2

      square = Base.style(CALayer.layer, {frame: [[sq_x, sq_y],[sq_size, sq_size]]})

      top_left = Base.style(CALayer.layer, frame: [[0, 0], [line_length, sq_border]], backgroundColor: border_color)
      top_right = Base.style(CALayer.layer, frame: [[sq_size-line_length, 0], [line_length, sq_border]], backgroundColor: border_color)
      left_top = Base.style(CALayer.layer, frame: [[0, sq_border], [sq_border, line_length - sq_border]], backgroundColor: border_color)
      right_top = Base.style(CALayer.layer, frame: [[sq_size - sq_border, sq_border], [sq_border, line_length - sq_border]], backgroundColor: border_color)
      left_bottom = Base.style(CALayer.layer, frame: [[0, sq_size - line_length], [sq_border, line_length - sq_border]], backgroundColor: border_color)
      right_bottom = Base.style(CALayer.layer, frame: [[sq_size - sq_border, sq_size - line_length], [sq_border, line_length - sq_border]], backgroundColor: border_color)
      bottom_left = Base.style(CALayer.layer, frame: [[0, sq_size - sq_border], [line_length, sq_border]], backgroundColor: border_color)
      bottom_right = Base.style(CALayer.layer, frame: [[sq_size-line_length, sq_size - sq_border], [line_length, sq_border]], backgroundColor: border_color)

      square.addSublayer top_left
      square.addSublayer top_right
      square.addSublayer left_top
      square.addSublayer right_top
      square.addSublayer left_bottom
      square.addSublayer right_bottom
      square.addSublayer bottom_left
      square.addSublayer bottom_right

      self.view.layer.addSublayer square

      @output.rectOfInterest = [[sq_y / camera_size.height, sq_x / camera_size.width], [sq_size / camera_size.height, sq_size / camera_size.width]]

      @session.addInput @input
      @session.addOutput @output
      @output.metadataObjectTypes = ( @types || [AVMetadataObjectTypeQRCode] )

      @isScanning = true

      @session.startRunning

      true
    end

    def captureOutput(captureOutput, didOutputMetadataObjects: metadataObjects, fromConnection: connection)
      metadataObject = metadataObjects[0]

      if !@scanned && metadataObject.present?
        @scanned = true

        self.performSelectorOnMainThread('openQRCode:', withObject: metadataObject.stringValue, waitUntilDone: false)
      end
    end

    def openQRCode(result)
      stop_scanning

      self.dismissViewControllerAnimated(true, completion: -> {
            @events[:result_scanned].call(result)
          })
    end

    def stop_scanning

      NSObject.cancelPreviousPerformRequestsWithTarget(self)

      if @isScanning
        @isScanning = false

        @session.stopRunning

        @previewLayer.removeFromSuperlayer
        @previewLayer = nil

        @session = nil
      end
      self.navigationItem.leftBarButtonItem = nil
    end

    def fake_scan
      @load_view.stop_loading
      @isScanning = false
      @events[:fake_result].call do |result|
        fake_result = result
      end unless @events[:fake_result].nil?
      fake_result ||= "#{rand(100)+1}"
      openQRCode(fake_result)
    end

    def on(event, &block)
      @events[event] = block.weak!
      self
    end

    def init
      super
      @events={}
      self
    end

    def dealloc
      ap "#{self.class.name} dealloc"
      super
    end

  end
end
