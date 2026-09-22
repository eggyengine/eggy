package com.eggyengine.eggy;

import org.libsdl.app.SDLActivity;

public class EggyActivity extends SDLActivity {
    @Override
    protected String[] getLibraries() {
        return new String[] { "SDL3", "main" };
    }
}
