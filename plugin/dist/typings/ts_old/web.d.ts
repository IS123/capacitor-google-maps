import { WebPlugin } from '@capacitor/core';
import { LatLngBounds } from './definitions';
import { type AddMarkerArgs, type CameraArgs, type AddMarkersArgs, type CapacitorGoogleMapsPlugin, type CreateMapArgs, type CurrentLocArgs, type DestroyMapArgs, type MapTypeArgs, type PaddingArgs, type RemoveMarkerArgs, type TrafficLayerArgs, type RemoveMarkersArgs, type MapBoundsContainsArgs, type EnableClusteringArgs, type FitBoundsArgs, type MapBoundsExtendArgs, type AddPolygonsArgs, type RemovePolygonsArgs, type AddCirclesArgs, type RemoveCirclesArgs, type AddPolylinesArgs, type RemovePolylinesArgs, type GroundOverlayArgs, type UpdateMarkerArgs, type UpdateMarkerIconArgs, type RemoveMarkerBymIdArgs, type RemoveMarkersBymIdArgs, UpdateMarkerBymIdArgs, UpdateMarkersBymIdArgs } from './implementation';
export declare class CapacitorGoogleMapsWeb extends WebPlugin implements CapacitorGoogleMapsPlugin {
    private gMapsRef;
    private AdvancedMarkerElement;
    private PinElement;
    private maps;
    private currMarkerId;
    private currPolygonId;
    private currCircleId;
    private currPolylineId;
    private currMapId;
    private onClusterClickHandler;
    private getIdFromMap;
    private getIdFromMarker;
    private importGoogleLib;
    enableTouch(_args: {
        id: string;
    }): Promise<void>;
    disableTouch(_args: {
        id: string;
    }): Promise<void>;
    setCamera(_args: CameraArgs): Promise<void>;
    getMapType(_args: {
        id: string;
    }): Promise<{
        type: string;
    }>;
    setMapType(_args: MapTypeArgs): Promise<void>;
    enableIndoorMaps(): Promise<void>;
    enableTrafficLayer(_args: TrafficLayerArgs): Promise<void>;
    enableAccessibilityElements(): Promise<void>;
    dispatchMapEvent(): Promise<void>;
    enableCurrentLocation(_args: CurrentLocArgs): Promise<void>;
    setPadding(_args: PaddingArgs): Promise<void>;
    getMapBounds(_args: {
        id: string;
    }): Promise<LatLngBounds>;
    fitBounds(_args: FitBoundsArgs): Promise<void>;
    addMarkers(_args: AddMarkersArgs): Promise<{
        ids: string[];
    }>;
    addMarker(_args: AddMarkerArgs): Promise<{
        id: string;
    }>;
    updateMarker(args: UpdateMarkerArgs): Promise<{
        id: string;
    }>;
    updateMarkerIcon(args: UpdateMarkerIconArgs): Promise<void>;
    removeMarkers(_args: RemoveMarkersArgs): Promise<void>;
    removeMarker(_args: RemoveMarkerArgs): Promise<void>;
    removeMarkerBymId(args: RemoveMarkerBymIdArgs): Promise<void>;
    removeMarkersBymId(args: RemoveMarkersBymIdArgs): Promise<void>;
    getMarkersIds(args: {
        id: string;
    }): Promise<Record<string, string>>;
    updateMarkerBymId(args: UpdateMarkerBymIdArgs): Promise<{
        id: string;
    }>;
    updateMarkersBymId(args: UpdateMarkersBymIdArgs): Promise<{
        ids: string[];
    }>;
    addPolygons(args: AddPolygonsArgs): Promise<{
        ids: string[];
    }>;
    removePolygons(args: RemovePolygonsArgs): Promise<void>;
    addCircles(args: AddCirclesArgs): Promise<{
        ids: string[];
    }>;
    removeCircles(args: RemoveCirclesArgs): Promise<void>;
    addPolylines(args: AddPolylinesArgs): Promise<{
        ids: string[];
    }>;
    removePolylines(args: RemovePolylinesArgs): Promise<void>;
    enableClustering(_args: EnableClusteringArgs): Promise<void>;
    disableClustering(_args: {
        id: string;
    }): Promise<void>;
    onScroll(): Promise<void>;
    onResize(): Promise<void>;
    onDisplay(): Promise<void>;
    create(_args: CreateMapArgs): Promise<void>;
    destroy(_args: DestroyMapArgs): Promise<void>;
    mapBoundsContains(_args: MapBoundsContainsArgs): Promise<{
        contains: boolean;
    }>;
    mapBoundsExtend(_args: MapBoundsExtendArgs): Promise<{
        bounds: LatLngBounds;
    }>;
    takeSnapshot(_args: {
        id: string;
        format?: string;
        quality?: number;
    }): Promise<{
        snapshot: string | HTMLElement;
    }>;
    addGroundOverlay(_args: GroundOverlayArgs): Promise<void>;
    getZoomLevel(_args: {
        id: string;
    }): Promise<{
        zoomLevel: number | undefined;
    }>;
    hasIcon(): Promise<{
        hasIcon: boolean;
    }>;
    setSelectionType(): Promise<void>;
    private getLatLngBounds;
    setCircleListeners(mapId: string, circleId: string, circle: google.maps.Circle): Promise<void>;
    setPolygonListeners(mapId: string, polygonId: string, polygon: google.maps.Polygon): Promise<void>;
    setPolylineListeners(mapId: string, polylineId: string, polyline: google.maps.Polyline): Promise<void>;
    setMarkerListeners(mapId: string, markerId: string, mId: string, marker: google.maps.marker.AdvancedMarkerElement): Promise<void>;
    setMapListeners(mapId: string): Promise<void>;
    private buildMarkerOpts;
}
