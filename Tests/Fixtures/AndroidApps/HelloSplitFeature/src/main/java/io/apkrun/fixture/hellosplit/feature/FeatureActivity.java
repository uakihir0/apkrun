package io.apkrun.fixture.hellosplit.feature;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

public final class FeatureActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i("APKRUN-FIXTURE", "feature loaded");
        TextView message = new TextView(this);
        message.setText("Install-time feature is present");
        setContentView(message);
    }
}
