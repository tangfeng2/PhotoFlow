import 'package:flutter/material.dart';

import 'pages/home_page.dart';

void main() => runApp(const PhotosApp());

class PhotosApp extends StatelessWidget {
  const PhotosApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'PhotoFlow',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff0a84ff),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xff0a84ff),
        brightness: Brightness.dark,
      ),
      home: const PhotosHomePage(),
    );
  }
}
