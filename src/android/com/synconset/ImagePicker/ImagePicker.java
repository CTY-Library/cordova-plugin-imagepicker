/**
 * An Image Picker Plugin for Cordova/PhoneGap.
 */
package com.synconset;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;

import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;


public class ImagePicker extends CordovaPlugin {

    private static final String ACTION_GET_PICTURES = "getPictures";
    private static final String ACTION_HAS_READ_PERMISSION = "hasReadPermission";
    private static final String ACTION_REQUEST_READ_PERMISSION = "requestReadPermission";
    private static final String ACTION_OPEN_APP_SETTINGS = "openAppSettings";

    private static final int PERMISSION_REQUEST_CODE_PICKER = 100;
    private static final int PERMISSION_REQUEST_CODE_ONLY = 101;

    private static final String ERROR_PERMISSION_DENIED_FIRST_TIME = "PERMISSION_DENIED_FIRST_TIME";
    private static final String ERROR_PERMISSION_DENIED_NEED_SETTINGS = "PERMISSION_DENIED_NEED_SETTINGS";
    private static final String ERROR_OPEN_SETTINGS_FAILED = "OPEN_SETTINGS_FAILED";

    private CallbackContext callbackContext;
    private Intent pendingImagePickerIntent;

    public boolean execute(String action, final JSONArray args, final CallbackContext callbackContext) throws JSONException {
        this.callbackContext = callbackContext;

        if (ACTION_HAS_READ_PERMISSION.equals(action)) {
            callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.OK, hasReadPermission()));
            return true;

        } else if (ACTION_REQUEST_READ_PERMISSION.equals(action)) {
            requestReadPermission(PERMISSION_REQUEST_CODE_ONLY);
            return true;

        } else if (ACTION_OPEN_APP_SETTINGS.equals(action)) {
            openAppSettings();
            return true;

        } else if (ACTION_GET_PICTURES.equals(action)) {
            final JSONObject params = args.getJSONObject(0);
            final Intent imagePickerIntent = new Intent(cordova.getActivity(), MultiImageChooserActivity.class);
            int max = 20;
            int desiredWidth = 0;
            int desiredHeight = 0;
            int quality = 100;
            int outputType = 0;
            boolean includeThumb = false;
            if (params.has("maximumImagesCount")) {
                max = params.getInt("maximumImagesCount");
            }
            if (params.has("width")) {
                desiredWidth = params.getInt("width");
            }
            if (params.has("height")) {
                desiredHeight = params.getInt("height");
            }
            if (params.has("quality")) {
                quality = params.getInt("quality");
            }
            if (params.has("outputType")) {
                outputType = params.getInt("outputType");
            }
            if (params.has("includeThumb")) {
                includeThumb = params.getBoolean("includeThumb");
            }

            imagePickerIntent.putExtra("MAX_IMAGES", max);
            imagePickerIntent.putExtra("WIDTH", desiredWidth);
            imagePickerIntent.putExtra("HEIGHT", desiredHeight);
            imagePickerIntent.putExtra("QUALITY", quality);
            imagePickerIntent.putExtra("OUTPUT_TYPE", outputType);
            imagePickerIntent.putExtra("INCLUDE_THUMB", includeThumb);

            // some day, when everybody uses a cordova version supporting 'hasPermission', enable this:
            /*
            if (cordova != null) {
                 if (cordova.hasPermission(Manifest.permission.READ_EXTERNAL_STORAGE)) {
                    cordova.startActivityForResult(this, imagePickerIntent, 0);
                 } else {
                     cordova.requestPermission(
                             this,
                             PERMISSION_REQUEST_CODE,
                             Manifest.permission.READ_EXTERNAL_STORAGE
                     );
                 }
             }
             */
            // .. until then use:
            if (hasReadPermission()) {
                cordova.startActivityForResult(this, imagePickerIntent, 0);
            } else {
                pendingImagePickerIntent = imagePickerIntent;
                requestReadPermission(PERMISSION_REQUEST_CODE_PICKER);
            }
            return true;
        }
        return false;
    }

    @SuppressLint("InlinedApi")
    private boolean hasReadPermission() {
        String readPermission = getReadPermission();
        return Build.VERSION.SDK_INT < 23 ||
                PackageManager.PERMISSION_GRANTED == ContextCompat.checkSelfPermission(this.cordova.getActivity(), readPermission);
    }

    @SuppressLint("InlinedApi")
    private String getReadPermission() {
        if (android.os.Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return Manifest.permission.READ_MEDIA_IMAGES;
        }

        return Manifest.permission.READ_EXTERNAL_STORAGE;
    }

    private boolean shouldPromptToOpenSettings() {
        String permission = getReadPermission();
        return !ActivityCompat.shouldShowRequestPermissionRationale(cordova.getActivity(), permission);
    }

    private void sendPermissionError(String code, String message) {
        JSONObject payload = new JSONObject();
        try {
            payload.put("code", code);
            payload.put("message", message);
            callbackContext.sendPluginResult(new PluginResult(PluginResult.Status.ERROR, payload));
        } catch (JSONException e) {
            callbackContext.error(code);
        }
    }

    private void sendDeniedResult(boolean hasGrantResult) {
        if (!hasGrantResult) {
            sendPermissionError(ERROR_PERMISSION_DENIED_FIRST_TIME,
                    "Permission request dismissed");
        } else if (shouldPromptToOpenSettings()) {
            sendPermissionError(ERROR_PERMISSION_DENIED_NEED_SETTINGS,
                    "Permission denied. Change your setting > this app > Photos and videos enable");
        } else {
            sendPermissionError(ERROR_PERMISSION_DENIED_FIRST_TIME, "Permission denied");
        }
    }

    @SuppressLint("InlinedApi")
    private void requestReadPermission(int requestCode) {
        if (!hasReadPermission()) {
            List<String> permissions = new ArrayList<String>();
            permissions.add(getReadPermission());
            cordova.requestPermissions(this, requestCode, permissions.toArray(new String[0]));
            return;
        }

        callbackContext.success();
    }

    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (resultCode == Activity.RESULT_OK && data != null) {
            int sync = data.getIntExtra("bigdata:synccode", -1);
            final Bundle bigData = ResultIPC.get().getLargeData(sync);
            if (bigData == null) {
                callbackContext.error("Failed to read picker result");
                return;
            }

            ArrayList<String> fileNames = bigData.getStringArrayList("MULTIPLEFILENAMES");
            ArrayList<String> thumbs = bigData.getStringArrayList("MULTIPLETHUMBS");
            if (fileNames == null) {
                callbackContext.error("No images selected");
                return;
            }

            JSONArray res;
            if (thumbs != null && thumbs.size() == fileNames.size()) {
                res = new JSONArray();
                try {
                    for (int i = 0; i < fileNames.size(); i++) {
                        JSONObject entry = new JSONObject();
                        entry.put("uri", fileNames.get(i));
                        if (thumbs.get(i) != null) {
                            entry.put("thumb", thumbs.get(i));
                        }
                        res.put(entry);
                    }
                } catch (JSONException e) {
                    callbackContext.error("Failed to build picker response");
                    return;
                }
            } else {
                res = new JSONArray(fileNames);
            }

            callbackContext.success(res);

        } else if (resultCode == Activity.RESULT_CANCELED && data != null) {
            String error = data.getStringExtra("ERRORMESSAGE");
            callbackContext.error(error != null ? error : "No images selected");

        } else if (resultCode == Activity.RESULT_CANCELED) {
            JSONArray res = new JSONArray();
            callbackContext.success(res);

        } else {
            callbackContext.error("No images selected");
        }
    }

    @Override
    public void onRequestPermissionResult(int requestCode,
                                          String[] permissions,
                                          int[] grantResults) throws JSONException {
        boolean hasGrantResult = grantResults != null && grantResults.length > 0;
        boolean granted = hasGrantResult && grantResults[0] == PackageManager.PERMISSION_GRANTED;

        if (requestCode == PERMISSION_REQUEST_CODE_PICKER) {
            if (granted && pendingImagePickerIntent != null) {
                cordova.startActivityForResult(this, pendingImagePickerIntent, 0);
            } else {
                sendDeniedResult(hasGrantResult);
            }
            pendingImagePickerIntent = null;
            return;
        }

        if (requestCode == PERMISSION_REQUEST_CODE_ONLY) {
            if (granted) {
                callbackContext.success();
            } else {
                sendDeniedResult(hasGrantResult);
            }
        }
    }

    private void openAppSettings() {
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
        Uri uri = Uri.fromParts("package", cordova.getActivity().getPackageName(), null);
        intent.setData(uri);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);

        try {
            cordova.getActivity().startActivity(intent);
            callbackContext.success();
        } catch (Exception e) {
            sendPermissionError(ERROR_OPEN_SETTINGS_FAILED, "Could not open app settings.");
        }
    }

    /**
     * Choosing a picture launches another Activity, so we need to implement the
     * save/restore APIs to handle the case where the CordovaActivity is killed by the OS
     * before we get the launched Activity's result.
     *
     * @see http://cordova.apache.org/docs/en/dev/guide/platforms/android/plugin.html#launching-other-activities
     */
    public void onRestoreStateForActivityResult(Bundle state, CallbackContext callbackContext) {
        this.callbackContext = callbackContext;
    }

}
