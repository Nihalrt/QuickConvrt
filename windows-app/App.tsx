import React, {useRef, useState} from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TurboModuleRegistry,
  useWindowDimensions,
  View,
} from 'react-native';
import type {TurboModule} from 'react-native';

interface FileOperations extends TurboModule {
  pick(folder: boolean, allFiles: boolean): Promise<string[]>;
  convert(sources: string[], folder: string, format: string, mode: string): Promise<string>;
  showFolder(folder: string): Promise<void>;
}

const formats = [
  {name: 'PDF', extension: 'pdf', icon: '\uE7C3'},
  {name: 'DOCX', extension: 'docx', icon: '\uE8A5'},
  {name: 'JPEG', extension: 'jpg', icon: '\uEB9F'},
  {name: 'PNG', extension: 'png', icon: '\uE91B'},
  {name: 'TIFF', extension: 'tiff', icon: '\uE8B9'},
  {name: 'TXT', extension: 'txt', icon: '\uE8A5'},
  {name: 'Compress', extension: 'zip', icon: '\uE7B8'},
] as const;
type Format = (typeof formats)[number];
type Mode = 'flowing' | 'layout';
const compressionModes = [
  {key: 'reduce-size', label: 'Reduce file size'},
  {key: 'zip', label: 'Create ZIP'},
] as const;
type CompressionMode = (typeof compressionModes)[number]['key'];
const modules = () => TurboModuleRegistry.getEnforcing<FileOperations>('QuickConvrtFiles');

function filename(path: string) {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

function parentFolder(path: string) {
  const separator = Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
  return path.slice(0, separator + 1);
}

function extension(path: string) {
  const suffix = filename(path).split('.').pop()?.toLowerCase() ?? '';
  return suffix === 'jpeg' ? 'jpg' : suffix === 'tif' ? 'tiff' : suffix;
}

function errorText(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

export default function App() {
  const {width} = useWindowDimensions();
  const size = Math.min(320, Math.max(264, width - 48));
  const center = size / 2;
  const radius = size * 0.345;
  const [format, setFormat] = useState<Format>(formats[0]);
  const [mode, setMode] = useState<Mode>('flowing');
  const [compressionOverride, setCompressionOverride] = useState<CompressionMode>();
  const [hovered, setHovered] = useState<Format>();
  const [files, setFiles] = useState<string[]>([]);
  const [folder, setFolder] = useState('');
  const [status, setStatus] = useState('');
  const [error, setError] = useState('');
  const [savedFolder, setSavedFolder] = useState('');
  const [busy, setBusy] = useState(false);
  const operation = useRef(false);

  const compressing = format.extension === 'zip';
  const compressionMode = compressionOverride ??
    (files.length && files.every(path => ['pdf', 'jpg', 'png'].includes(extension(path))) ? 'reduce-size' : 'zip');
  const creatingZip = compressing && compressionMode === 'zip';
  const pending = compressing ? files : files.filter(path => extension(path) !== format.extension);
  const skipped = files.length - pending.length;
  const needsWordMode = format.extension === 'docx' && pending.some(path => extension(path) === 'pdf');

  async function choose(wantFolder: boolean) {
    if (operation.current) return;
    operation.current = true;
    try {
      const paths = await modules().pick(wantFolder, compressing);
      if (!paths.length) return;
      setError('');
      setStatus('');
      if (wantFolder) {
        setFolder(paths[0]);
      } else {
        setFiles([...new Set(paths)].slice(0, 20));
        setCompressionOverride(undefined);
        setSavedFolder('');
        if (paths.length > 20) setStatus('The first 20 files were selected.');
      }
    } catch (cause) {
      setError(errorText(cause));
    } finally {
      operation.current = false;
    }
  }

  async function convert() {
    if (operation.current || !pending.length) return;
    operation.current = true;
    setBusy(true);
    setSavedFolder('');
    setError('');
    setStatus('');
    try {
      const destination = folder || (await modules().pick(true, false))[0];
      if (!destination) return;
      setFolder(destination);
      if (creatingZip) {
        setStatus('Compressing…');
        const archive = await modules().convert(pending, destination, 'zip', mode);
        setFiles([]);
        setSavedFolder(parentFolder(archive));
        setStatus(`Saved ${filename(archive)}.`);
        return;
      }
      const converted = new Set<string>();
      const savedPaths: string[] = [];
      const failures: string[] = [];
      for (const [index, path] of pending.entries()) {
        setStatus(`${compressing ? 'Compressing' : 'Converting'} ${index + 1} of ${pending.length}…`);
        try {
          const saved = await modules().convert([path], destination, compressing ? compressionMode : format.extension, mode);
          savedPaths.push(saved);
          converted.add(path);
        } catch (cause) {
          failures.push(`${filename(path)}: ${errorText(cause)}`);
        }
      }
      setFiles(files.filter(path => !converted.has(path)));
      if (savedPaths.length) setSavedFolder(savedPaths.length === 1 ? parentFolder(savedPaths[0]) : destination);
      setStatus(compressing
        ? (converted.size === 1 ? '1 smaller copy saved' : `${converted.size} smaller copies saved`)
        : `${converted.size} saved${skipped ? `, ${skipped} skipped` : ''}`);
      setError(failures.join('\n'));
    } catch (cause) {
      setStatus('');
      setError(errorText(cause));
    } finally {
      operation.current = false;
      setBusy(false);
    }
  }

  return (
    <ScrollView style={styles.background} contentContainerStyle={styles.page}>
      <Text accessibilityRole="header" style={styles.title}>QuickConvrt</Text>
      <View style={[styles.wheel, {width: size, height: size, borderRadius: center}]}>
        {formats.map((item, index) => {
          const slice = 2 * Math.PI / formats.length;
          const angle = index * slice - Math.PI / 2;
          const edgeAngle = angle + slice / 2;
          const selected = item === format;
          return (
            <React.Fragment key={item.extension}>
              <View pointerEvents="none" style={[styles.divider, {
                width: size * 0.30,
                left: center + size * 0.35 * Math.cos(edgeAngle) - size * 0.15,
                top: center + size * 0.35 * Math.sin(edgeAngle),
                transform: [{rotate: `${edgeAngle}rad`}],
              }]} />
              <Pressable
                accessibilityRole="button"
                accessibilityLabel={item.extension === 'zip' ? 'Compress files' : `Select ${item.name} output`}
                accessibilityState={{selected, disabled: busy}}
                disabled={busy}
                onHoverIn={() => setHovered(item)}
                onHoverOut={() => setHovered(current => current === item ? undefined : current)}
                onPress={() => {setFormat(item); setStatus(''); setError('');}}
                style={({pressed}) => [
                  styles.format,
                  {left: center + radius * Math.cos(angle) - 34, top: center + radius * Math.sin(angle) - 33},
                  selected && styles.selected,
                  (pressed || hovered === item) && styles.focus,
                  hovered === item && styles.raised,
                ]}>
                <Text style={[styles.icon, selected && styles.accent]}>{item.icon}</Text>
                <Text style={[styles.formatLabel, selected && styles.accent]}>{item.name}</Text>
              </Pressable>
            </React.Fragment>
          );
        })}
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Add files"
          disabled={busy}
          onPress={() => choose(false)}
          style={({pressed}) => [
            styles.lens, {left: center - 43, top: center - 43},
            pressed && styles.focus,
          ]}>
          <Text style={styles.icon}>{'\uE710'}</Text>
          <Text style={styles.formatLabel}>{files.length ? `${files.length} selected` : 'Add files'}</Text>
        </Pressable>
      </View>

      <View style={styles.details}>
        {!!files.length && (
          <Text style={styles.text} numberOfLines={1} ellipsizeMode="middle">
            {files.length === 1 ? filename(files[0]) : `${files.length} files selected`}
          </Text>
        )}
        {needsWordMode && (
          <View style={styles.modes}>
            {([{key: 'flowing', label: 'Editable paragraphs'}, {key: 'layout', label: 'Page layout'}] as const).map(item => (
              <Pressable key={item.key} accessibilityRole="button" accessibilityState={{selected: mode === item.key}}
                disabled={busy} onPress={() => setMode(item.key)}
                style={({pressed}) => [styles.mode, mode === item.key && styles.selected, pressed && styles.focus]}>
                <Text style={styles.text}>{item.label}</Text>
              </Pressable>
            ))}
          </View>
        )}
        {compressing && !!files.length && (
          <>
            <View style={styles.modes}>
              {compressionModes.map(item => (
                <Pressable key={item.key} accessibilityRole="button" accessibilityState={{selected: compressionMode === item.key}}
                  disabled={busy} onPress={() => setCompressionOverride(item.key)}
                  style={({pressed}) => [styles.mode, compressionMode === item.key && styles.selected, pressed && styles.focus]}>
                  <Text style={styles.text}>{item.label}</Text>
                </Pressable>
              ))}
            </View>
            {compressionMode === 'reduce-size' && <Text style={styles.text}>PDF and JPEG image quality may be reduced.</Text>}
          </>
        )}
        <Pressable accessibilityRole="button" accessibilityLabel={folder ? `Save to ${folder}` : 'Choose a save folder'}
          disabled={busy} onPress={() => choose(true)}
          style={({pressed}) => [styles.button, pressed && styles.focus]}>
          <Text style={styles.text} numberOfLines={1} ellipsizeMode="middle">{folder ? `Save to  ${folder}` : 'Choose save folder…'}</Text>
        </Pressable>
        {!!files.length && (
          <Pressable accessibilityRole="button" accessibilityState={{disabled: busy || !pending.length}}
            disabled={busy || !pending.length} onPress={convert}
            style={({pressed}) => [styles.button, styles.convert, pressed && styles.focus, (busy || !pending.length) && styles.disabled]}>
            {busy ? <ActivityIndicator color="#d2f7e7" /> :
              <Text style={styles.text}>{creatingZip ? 'Create ZIP' : compressing ? 'Reduce file size' : pending.length ? `Convert to ${format.name}` : `Already ${format.name}`}</Text>}
          </Pressable>
        )}
        {!!status && <Text accessibilityLiveRegion="polite" style={styles.text}>{status}</Text>}
        {!!error && <Text accessibilityLiveRegion="polite" style={styles.error}>{error}</Text>}
        {!!savedFolder && (
          <Pressable accessibilityRole="button"
            onPress={() => {modules().showFolder(savedFolder).catch(cause => setError(errorText(cause)));}}
            style={({pressed}) => [styles.button, pressed && styles.focus]}>
            <Text style={styles.text}>Open output folder</Text>
          </Pressable>
        )}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  background: {flex: 1, backgroundColor: '#111c22'},
  page: {alignItems: 'center', padding: 24, gap: 20},
  title: {fontSize: 24, fontWeight: '700', color: '#e3f4ef'},
  wheel: {position: 'relative', borderWidth: 1, borderColor: '#546969', backgroundColor: '#293c40'},
  divider: {position: 'absolute', height: 1, backgroundColor: '#546969'},
  format: {position: 'absolute', width: 68, height: 66, borderRadius: 23, borderWidth: 1, borderColor: 'transparent', alignItems: 'center', justifyContent: 'center', gap: 4},
  lens: {position: 'absolute', width: 86, height: 86, borderRadius: 43, borderWidth: 1, borderColor: '#6f9d90', alignItems: 'center', justifyContent: 'center', gap: 5, backgroundColor: '#365a54'},
  selected: {borderColor: '#87cbb3', backgroundColor: '#365a54'},
  raised: {transform: [{scale: 1.08}]},
  focus: {borderColor: '#d2f7e7', backgroundColor: '#41645e'},
  icon: {fontFamily: 'Segoe MDL2 Assets', fontSize: 20, color: '#e3f4ef'},
  formatLabel: {fontSize: 11, color: '#e3f4ef', fontWeight: '600'},
  accent: {color: '#b2eed8'},
  details: {width: '100%', maxWidth: 380, alignItems: 'stretch', gap: 10},
  text: {color: '#e3f4ef', fontSize: 14, textAlign: 'center'},
  error: {color: '#ffb6b6', fontSize: 13},
  modes: {flexDirection: 'row', gap: 8},
  mode: {flex: 1, borderWidth: 1, borderColor: '#546969', borderRadius: 16, padding: 8},
  button: {borderWidth: 1, borderColor: '#546969', borderRadius: 18, backgroundColor: '#293c40', minHeight: 36, padding: 8, justifyContent: 'center'},
  convert: {backgroundColor: '#356351', borderColor: '#83baa6'},
  disabled: {opacity: 0.6},
});
