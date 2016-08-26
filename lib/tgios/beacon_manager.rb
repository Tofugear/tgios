# Localize authorization request alert in your Localizable.strings
# "Tgios::BeaconManager.request_alert.title.denied" = "Location services are off";
# "Tgios::BeaconManager.request_alert.title.disabled" = "Background location is not enabled";
# "Tgios::BeaconManager.request_alert.message" = "To use background location you must turn on 'Always' in the Location Services Settings";

module Tgios
  class FakeBeacon
    attr_accessor :proximityUUID, :major, :minor, :accuracy, :proximity, :rssi

    def initialize(attributes)
      attributes.each do |k, v|
        k = :proximityUUID if k.to_s == 'uuid'
        instance_variable_set("@#{k}", v)
      end
    end
  end

  class BeaconManager < BindingBase
    attr_accessor :range_method, :range_limit, :tolerance, :current_beacon, :background

    BeaconFoundKey = 'Tgios::BeaconManager::BeaconFound'
    BeaconsFoundKey = 'Tgios::BeaconManager::BeaconsFound'
    EnterRegionKey = 'Tgios::BeaconManager::EnterRegion'
    ExitRegionKey = 'Tgios::BeaconManager::ExitRegion'

    def self.default=(val)
      @default = val
    end

    def self.default
      @default
    end

    #############################################
    # range_method: :rssi or :accuracy
    # range_limit: around -70 for :rssi / around 1.5 (meters) for :accuracy
    # tolerance: number of times a beacon is ranged continuously required to trigger beacon changed event
    # background: range beacons when device is in background
    #############################################

    def initialize(options)
      @events = {}
      @previous_beacons = []
      @background = options[:background]
      @tolerance = (options[:tolerance] || 5)

      @uuid = NSUUID.alloc.initWithUUIDString(options[:uuid])
      @major = options[:major]
      @minor = options[:minor]
      @range_method = (options[:range_method] || :rssi)
      @range_limit = (options[:range_limit] || -70)

      @region = if @major && @minor
                  CLBeaconRegion.alloc.initWithProximityUUID(@uuid, major: @major, minor: @minor, identifier: identifier)
                elsif @major
                  CLBeaconRegion.alloc.initWithProximityUUID(@uuid, major: @major, identifier: identifier)
                else
                  CLBeaconRegion.alloc.initWithProximityUUID(@uuid, identifier: identifier)
                end
      @region.notifyOnEntry = true
      @region.notifyOnExit = true
      @region.notifyEntryStateOnDisplay = true

      start_monitor

      UIApplicationWillEnterForegroundNotification.add_observer(self, 'on_enter_foreground:')
      UIApplicationDidEnterBackgroundNotification.add_observer(self, 'on_enter_background:')

    end

    def identifier
      [@uuid.UUIDString, @major, @minor].join('/')
    end

    def on(event_key,&block)
      @events[event_key] = block.weak!
      self
    end

    def locationManager(manager, didDetermineState: state, forRegion: region)
      NSLog "didDetermineState #{state}"
      if state == CLRegionStateInside
        manager.startRangingBeaconsInRegion(region)
      end
    end

    def locationManager(manager, didEnterRegion: region)
      NSLog 'didEnterRegion'
      if region.isKindOfClass(CLBeaconRegion)
        manager.startRangingBeaconsInRegion(region)
      end
    end

    def locationManager(manager, didExitRegion: region)
      NSLog 'didExitRegion'
      if region.isKindOfClass(CLBeaconRegion)
        manager.stopRangingBeaconsInRegion(region)
        if has_event(:exit_region)
          @events[:exit_region].call(region)
        end
      end
    end

    def locationManager(manager, didRangeBeacons: beacons, inRegion: region)
      beacons = beacons.sort_by{|b| b.try(@range_method)}
      beacons = beacons.reverse if @range_method == :rssi
      known_beacons = beacons.select{|b| b.proximity != CLProximityUnknown}
      unknown_beacons = beacons - known_beacons
      beacon = nil
      beacons_in_range = known_beacons.select{|b| @range_method == :accuracy ? b.try(@range_method) <= @range_limit : b.try(@range_method) >= @range_limit}
      beacon = beacons_in_range.first if beacons_in_range.present?
      
      NSLog("beacons_in_range: ")
      beacons_in_range.each_with_index do |bir, i|
        NSLog("##{i}: major: #{bir.major}, minor: #{bir.minor}, accuracy: #{bir.accuracy}, rssi: #{bir.rssi}")
      end
      push_beacon(beacon) # nil value will signify null beacon

      if has_event(:beacons_found)
        # use known_beacons + unknown_beacons to make sure closest range comes to the top
        @events[:beacons_found].call(beacons_in_range, known_beacons + unknown_beacons, @current_beacon)
      end

      if has_event(:beacon_found)
        @events[:beacon_found].call(@current_beacon)
      end

      BeaconFoundKey.post_notification(self, {region: region, beacon: @current_beacon})
      BeaconsFoundKey.post_notification(self, {region: region, beacons_in_range: beacons_in_range, any_beacons: known_beacons + unknown_beacons})
    end

    def location_manager
      @location_manager ||=
          begin
            manager = CLLocationManager.alloc.init
            manager.delegate = self
            request_authorization(manager)
            manager
          end
    end

    def request_authorization(manager)
      if manager.respond_to?(:requestAlwaysAuthorization)
        status = CLLocationManager.authorizationStatus
        if status == KCLAuthorizationStatusAuthorizedWhenInUse || status == KCLAuthorizationStatusDenied
          denied_title = 'Tgios::BeaconManager.request_alert.title.denied'._
          denied_title = 'Location services are off' if denied_title == 'Tgios::BeaconManager.request_alert.title.denied'

          disabled_title = 'Tgios::BeaconManager.request_alert.title.disabled'._
          disabled_title = 'Background location is not enabled' if disabled_title == 'Tgios::BeaconManager.request_alert.title.disabled'

          message = 'Tgios::BeaconManager.request_alert.message'._
          message = "To use background location you must turn on 'Always' in the Location Services Settings" if message == 'Tgios::BeaconManager.request_alert.message'

          title = (status == KCLAuthorizationStatusDenied) ? denied_title : disabled_title
          UIAlertView.alert(title, message: message)
        else
          manager.requestAlwaysAuthorization
        end
      end

    end

    def start_monitor
      location_manager.startMonitoringForRegion(@region)
      location_manager.requestStateForRegion(@region)
    end

    def stop_monitor
      location_manager.stopRangingBeaconsInRegion(@region)
      location_manager.stopMonitoringForRegion(@region)
    end

    def on_enter_foreground(noti)
      NSLog 'on_enter_foreground'
      self.performSelector('start_monitor', withObject: nil, afterDelay:1)
    end

    def on_enter_background(noti)
      NSLog 'on_enter_background'
      stop_monitor unless @background
    end

    def has_event(event)
      @events.has_key?(event)
    end

    def push_beacon(beacon)
      if beacon_eqs(beacon, @current_beacon)
        @current_beacon = beacon
      else
        if @previous_beacons.find { |b| !beacon_eqs(beacon, b) }.blank?
          @current_beacon = beacon
        else
          @current_beacon = nil if @previous_beacons.find{ |b| beacon_eqs(@current_beacon, b)}.blank?
        end
      end
      @previous_beacons << beacon
      @previous_beacons.delete_at(0) if @previous_beacons.length > @tolerance
    end

    def beacon_eqs(beacon1, beacon2)
      self.class.beacon_eqs(beacon1, beacon2)
    end

    def self.beacon_eqs(beacon1, beacon2)
      return beacon1 == beacon2 if beacon1.nil? || beacon2.nil?
      beacon1.minor == beacon2.minor && beacon1.major == beacon2.major && beacon1.proximityUUID == beacon2.proximityUUID
    end

    def new_fake_beacon(options)
      FakeBeacon.new({uuid: @uuid}.merge(options))
    end

    def self.supported
      CLLocationManager.isRangingAvailable
    end

    def onPrepareForRelease
      UIApplicationWillEnterForegroundNotification.remove_observer(self)
      UIApplicationDidEnterBackgroundNotification.remove_observer(self)
      stop_monitor
      @location_manager = nil
      @events = nil
      @current_beacon = nil
      @previous_beacons = nil
    end

    def dealloc
      onPrepareForRelease
      super
    end
  end
end
