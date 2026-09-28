// Adapted from Astronomy Engine 2.1.19 (MIT).
// Copyright (c) 2019-2023 Don Cross. See THIRD_PARTY_NOTICES.md.
part of 'celestial_directions.dart';

double _meanObliquity(AstronomicalTime time) {
  var t = time.ttDays / 36525;
  var asec =
      (((((-0.0000000434 * t - 0.000000576) * t + 0.00200340) * t - 0.0001831) *
                  t -
              46.836769) *
          t +
      84381.406);
  return asec / 3600.0;
}

({double dpsi, double deps}) _nutationAngles(AstronomicalTime time) {
  double mod(double x) {
    return (x % 1296000) * _arcsec;
  }

  final t = time.ttDays / 36525;
  final elp = mod(1287104.79305 + t * 129596581.0481);
  final f = mod(335779.526232 + t * 1739527262.8478);
  final d = mod(1072260.70369 + t * 1602961601.2090);
  final om = mod(450160.398036 - t * 6962890.5431);
  var sarg = math.sin(om);
  var carg = math.cos(om);
  var dp = (-172064161.0 - 174666.0 * t) * sarg + 33386.0 * carg;
  var de = (92052331.0 + 9086.0 * t) * carg + 15377.0 * sarg;
  var arg = 2.0 * (f - d + om);
  sarg = math.sin(arg);
  carg = math.cos(arg);
  dp += (-13170906.0 - 1675.0 * t) * sarg - 13696.0 * carg;
  de += (5730336.0 - 3015.0 * t) * carg - 4587.0 * sarg;
  arg = 2.0 * (f + om);
  sarg = math.sin(arg);
  carg = math.cos(arg);
  dp += (-2276413.0 - 234.0 * t) * sarg + 2796.0 * carg;
  de += (978459.0 - 485.0 * t) * carg + 1374.0 * sarg;
  arg = 2.0 * om;
  sarg = math.sin(arg);
  carg = math.cos(arg);
  dp += (2074554.0 + 207.0 * t) * sarg - 698.0 * carg;
  de += (-897492.0 + 470.0 * t) * carg - 291.0 * sarg;
  sarg = math.sin(elp);
  carg = math.cos(elp);
  dp += (1475877.0 - 3633.0 * t) * sarg + 11817.0 * carg;
  de += (73871.0 - 184.0 * t) * carg - 1924.0 * sarg;
  return (dpsi: -0.000135 + (dp * 1.0e-7), deps: 0.000388 + (de * 1.0e-7));
}

Mat4 _precession(AstronomicalTime time) {
  final t = time.ttDays / 36525;
  var eps0 = 84381.406;
  var psia =
      (((((-0.0000000951 * t + 0.000132851) * t - 0.00114045) * t - 1.0790069) *
              t +
          5038.481507) *
      t);
  var omegaa =
      (((((0.0000003337 * t - 0.000000467) * t - 0.00772503) * t + 0.0512623) *
                  t -
              0.025754) *
          t +
      eps0);
  var chia =
      (((((-0.0000000560 * t + 0.000170663) * t - 0.00121197) * t - 2.3814292) *
              t +
          10.556403) *
      t);
  eps0 *= _arcsec;
  psia *= _arcsec;
  omegaa *= _arcsec;
  chia *= _arcsec;
  final sa = math.sin(eps0);
  final ca = math.cos(eps0);
  final sb = math.sin(-psia);
  final cb = math.cos(-psia);
  final sc = math.sin(-omegaa);
  final cc = math.cos(-omegaa);
  final sd = math.sin(chia);
  final cd = math.cos(chia);
  final xx = cd * cb - sb * sd * cc;
  final yx = cd * sb * ca + sd * cc * cb * ca - sa * sd * sc;
  final zx = cd * sb * sa + sd * cc * cb * sa + ca * sd * sc;
  final xy = -sd * cb - sb * cd * cc;
  final yy = -sd * sb * ca + cd * cc * cb * ca - sa * cd * sc;
  final zy = -sd * sb * sa + cd * cc * cb * sa + ca * cd * sc;
  final xz = sb * sc;
  final yz = -sc * cb * ca - sa * cc;
  final zz = -sc * cb * sa + cc * ca;
  return Mat4([xx, xy, xz, 0, yx, yy, yz, 0, zx, zy, zz, 0, 0, 0, 0, 1]);
}

Mat4 _nutation(AstronomicalTime time) {
  final nut = _nutationAngles(time);
  final mean = _meanObliquity(time);
  final oblm = mean * _deg;
  final oblt = (mean + nut.deps / 3600) * _deg;
  final psi = nut.dpsi * _arcsec;
  final cobm = math.cos(oblm);
  final sobm = math.sin(oblm);
  final cobt = math.cos(oblt);
  final sobt = math.sin(oblt);
  final cpsi = math.cos(psi);
  final spsi = math.sin(psi);
  final xx = cpsi;
  final yx = -spsi * cobm;
  final zx = -spsi * sobm;
  final xy = spsi * cobt;
  final yy = cpsi * cobm * cobt + sobm * sobt;
  final zy = cpsi * sobm * cobt - cobm * sobt;
  final xz = spsi * sobt;
  final yz = cpsi * cobm * sobt - sobm * cobt;
  final zz = cpsi * sobm * sobt + cobm * cobt;
  return Mat4([xx, xy, xz, 0, yx, yy, yz, 0, zx, zy, zz, 0, 0, 0, 0, 1]);
}

Mat4 _moonFixed(AstronomicalTime time) {
  final d = time.ttDays, t = d / 36525;
  final e1 = _deg * (125.045 - 0.0529921 * d);
  final e2 = _deg * (250.089 - 0.1059842 * d);
  final e3 = _deg * (260.008 + 13.0120009 * d);
  final e4 = _deg * (176.625 + 13.3407154 * d);
  final e5 = _deg * (357.529 + 0.9856003 * d);
  final e6 = _deg * (311.589 + 26.4057084 * d);
  final e7 = _deg * (134.963 + 13.0649930 * d);
  final e8 = _deg * (276.617 + 0.3287146 * d);
  final e9 = _deg * (34.226 + 1.7484877 * d);
  final e10 = _deg * (15.134 - 0.1589763 * d);
  final e11 = _deg * (119.743 + 0.0036096 * d);
  final e12 = _deg * (239.961 + 0.1643573 * d);
  final e13 = _deg * (25.053 + 12.9590088 * d);
  final ra =
      (269.9949 +
      0.0031 * t -
      3.8787 * math.sin(e1) -
      0.1204 * math.sin(e2) +
      0.0700 * math.sin(e3) -
      0.0172 * math.sin(e4) +
      0.0072 * math.sin(e6) -
      0.0052 * math.sin(e10) +
      0.0043 * math.sin(e13));
  final dec =
      (66.5392 +
      0.0130 * t +
      1.5419 * math.cos(e1) +
      0.0239 * math.cos(e2) -
      0.0278 * math.cos(e3) +
      0.0068 * math.cos(e4) -
      0.0029 * math.cos(e6) +
      0.0009 * math.cos(e7) +
      0.0008 * math.cos(e10) -
      0.0009 * math.cos(e13));
  final w =
      (38.3213 +
      (13.17635815 - 1.4e-12 * d) * d +
      3.5610 * math.sin(e1) +
      0.1208 * math.sin(e2) -
      0.0642 * math.sin(e3) +
      0.0158 * math.sin(e4) +
      0.0252 * math.sin(e5) -
      0.0066 * math.sin(e6) -
      0.0047 * math.sin(e7) -
      0.0046 * math.sin(e8) +
      0.0028 * math.sin(e9) +
      0.0052 * math.sin(e10) +
      0.0040 * math.sin(e11) +
      0.0019 * math.sin(e12) -
      0.0044 * math.sin(e13));

  final north = Vec3(
    math.cos(dec * _deg) * math.cos(ra * _deg),
    math.cos(dec * _deg) * math.sin(ra * _deg),
    math.sin(dec * _deg),
  );
  final ascending = const Vec3(0, 0, 1).cross(north).normalized();
  final spin = w * _deg;
  final prime =
      (ascending * math.cos(spin) +
              north.cross(ascending) * math.sin(spin) +
              north * (north.dot(ascending) * (1 - math.cos(spin))))
          .normalized();
  final east = north.cross(prime).normalized();
  return Mat4([
    ...prime.storage,
    0,
    ...east.storage,
    0,
    ...north.storage,
    0,
    0,
    0,
    0,
    1,
  ]);
}
